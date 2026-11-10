import Foundation
import Network
import Security

struct HTTPRequest {
    var method: String
    var path: String
    var authorization: String?
    var body: Data
}
struct HTTPResponse {
    var status = 200
    var type = "application/json"
    var body = Data()
    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: jsonData(value))
    }
}

final class ProbeServer {
    private let queue = DispatchQueue(label: "probe.network")
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var token = ""
    private var droppedPackets: [String: Int] = [:]
    private var removedReasons: [String: Int] = [:]
    var handle: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    var onStream: ((String) -> Void)?
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var request = Data()
        var streaming = false
        var target = ""
        var busy = false
        var needKey = true
        var completed = false
        var lastSend = uptime()
        init(_ c: NWConnection) { connection = c }
    }
    func start(identity: SecIdentity, token: String, lan: Bool) throws {
        self.token = token
        let tls = NWProtocolTLS.Options()
        guard let identity = sec_identity_create(identity) else { throw ProbeFailure("tls_identity", "Invalid identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = .hostPort(host: lan ? "0.0.0.0" : "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port?.rawValue { self?.onReady?(port) }
            if case .failed(let error) = state { self?.onError?(error.localizedDescription) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 12 else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let peer else { return }
            if case .failed = state { self?.remove(peer) }
            if case .cancelled = state { self?.peers[peer.id] = nil }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
            if let peer, !peer.completed { self?.remove(peer) }
        }
        receive(peer)
    }
    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, done, error in
            guard let self, let peer else { return }
            if let data { peer.request.append(data) }
            if error != nil || (done && peer.request.isEmpty) { self.remove(peer); return }
            do {
                if let request = try Self.parse(peer.request) {
                    peer.completed = true
                    guard request.authorization == "Bearer \(self.token)" else {
                        self.respond(peer, .json(["error": "unauthorized"], status: 401)); return
                    }
                    if request.method == "GET", request.path.hasPrefix("/stream/") {
                        self.handle?(request) { [weak self, weak peer] response in
                            self?.queue.async {
                                guard let self, let peer else { return }
                                guard response.status == 200 else { self.respond(peer, response); return }
                                peer.target = String(request.path.dropFirst(8))
                                peer.streaming = true; peer.request.removeAll()
                                peer.connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-slz-probe\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                                self.onStream?(peer.target)
                                // Continue reading to observe a client close, even if this
                                // target never produces another frame or status packet.
                                peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak peer] _, _, _, _ in
                                    if let peer { self?.remove(peer) }
                                }
                            }
                        }
                    } else {
                        self.handle?(request) { [weak self, weak peer] response in
                            self?.queue.async { if let peer { self?.respond(peer, response) } }
                        }
                    }
                } else if done { self.remove(peer) } else { self.receive(peer) }
            } catch { self.respond(peer, .json(["error": "bad_request"], status: 400)) }
        }
    }
    static func parse(_ bytes: Data) throws -> HTTPRequest? {
        guard bytes.count <= 131072 else { throw ProbeFailure("request_limit", "Request too large") }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16384 { throw ProbeFailure("header_limit", "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 16384, let header = String(data: bytes.prefix(upTo: boundary.lowerBound), encoding: .utf8) else {
            throw ProbeFailure("bad_header", "Invalid headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        let start = lines[0].components(separatedBy: " ")
        guard start.count == 3, ["GET", "POST"].contains(start[0]), start[2] == "HTTP/1.1" else {
            throw ProbeFailure("bad_request", "Unsupported request")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ProbeFailure("bad_header", "Invalid field") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw ProbeFailure("duplicate_header", "Duplicate header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...65536).contains(length) else {
            throw ProbeFailure("bad_length", "Unsupported body length")
        }
        let end = boundary.upperBound + length
        guard bytes.count >= end else { return nil }
        guard bytes.count == end else { throw ProbeFailure("extra_request", "Pipelining is not supported") }
        return HTTPRequest(method: start[0], path: start[1], authorization: headers["authorization"], body: bytes.subdata(in: boundary.upperBound..<end))
    }
    private func respond(_ peer: Peer, _ response: HTTPResponse) {
        let header = "HTTP/1.1 \(response.status) Result\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8); data.append(response.body)
        peer.connection.send(content: data, completion: .contentProcessed { [weak self, weak peer] _ in
            self?.queue.async { if let peer { self?.remove(peer) } }
        })
    }
    func broadcast(_ packet: MediaPacket, target: String) {
        queue.async { [weak self] in
            guard let self, let bytes = try? packet.encoded() else { return }
            for peer in Array(self.peers.values) where peer.streaming && peer.target == target {
                // Keep one send in flight. JPEG/PNG frames are independent, so a
                // busy receiver can skip them without losing decoder state. Status
                // heartbeats can also be skipped while media is flowing.
                if peer.busy {
                    self.droppedPackets[packet.header.kind, default: 0] += 1
                    if packet.header.kind == "paused" || uptime() - peer.lastSend > 2 {
                        self.removedReasons[packet.header.kind == "paused" ? "paused_during_send" : "send_stalled", default: 0] += 1
                        self.remove(peer)
                    } else if packet.header.kind == "h264" { peer.needKey = true }
                    continue
                }
                if packet.header.kind == "h264", peer.needKey, !packet.header.keyframe { continue }
                if packet.header.kind == "h264" { peer.needKey = false }
                if packet.header.kind == "paused" { peer.needKey = true }
                peer.busy = true; peer.lastSend = uptime()
                var chunk = Data(String(bytes.count, radix: 16).utf8); chunk.append(Data("\r\n".utf8))
                chunk.append(bytes); chunk.append(Data("\r\n".utf8))
                peer.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak peer] error in
                    self?.queue.async {
                        guard let peer else { return }
                        peer.busy = false
                        if error != nil { self?.remove(peer) }
                    }
                })
            }
        }
    }
    func disconnectStreams() {
        queue.sync {
            for peer in Array(peers.values) where peer.streaming { remove(peer) }
        }
    }
    func stats() -> [String: Any] {
        queue.sync {
            ["peers": peers.count, "streams": peers.values.filter { $0.streaming }.map { $0.target },
             "droppedPackets": droppedPackets, "removedReasons": removedReasons]
        }
    }
    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for peer in peers.values { peer.connection.cancel() }
            peers.removeAll()
        }
    }
    private func remove(_ peer: Peer) { peer.connection.cancel(); peers[peer.id] = nil }
}
