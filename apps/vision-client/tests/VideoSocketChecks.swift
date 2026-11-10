import Foundation
import Network

nonisolated final class VideoSocketCheck: @unchecked Sendable {
    enum Mode { case normal, waiting, stalledRenderer, invalidMedia }
    private let queue = DispatchQueue(label: "slz.video-socket-test")
    private let mode: Mode
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private var retained: VideoSocketCheck?
    private var listener: NWListener?
    private var server: NWConnection?
    private var client: VideoSocket?
    private let nonce = UUID().uuidString
    private var candidates: [UUID: NWConnection] = [:]
    private var noise: NWConnection?
    private var finished = false
    private var acknowledgements = 0
    private var stateAcknowledgements = 0
    private var consumed = 0
    private var parser = VideoPacketParser()
    private let stream = UUID()
    init(mode: Mode, completion: @escaping @Sendable (Result<Void, Error>) -> Void) { self.mode = mode; self.completion = completion }
    static func run(_ mode: Mode) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let test = VideoSocketCheck(mode: mode) { continuation.resume(with: $0) }
            test.queue.async { test.start() }
        }
    }
    private func start() {
        retained = self
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                guard self.candidates.count < 8 else { connection.cancel(); return }
                let candidateID = UUID()
                self.candidates[candidateID] = connection
                connection.start(queue: self.queue)
                self.admit(connection, id: candidateID)
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.candidates.removeValue(forKey: candidateID)?.cancel() }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = listener.port {
                    // Real companions probe loopback listeners for web frontends.
                    // Such a probe must not replace the authenticated test peer.
                    let noise = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                    self.noise = noise
                    noise.start(queue: self.queue)
                    noise.send(content: Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                    let client = VideoSocket(connection: connection, request: Data("GET /fixture HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(self.nonce)\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\n\r\n".utf8), consume: { [weak self] packets, deadline, complete in
                        guard let self else { return }
                        self.queue.async {
                            guard !self.finished else { return }
                            precondition(ProcessInfo.processInfo.systemUptime < deadline)
                            self.consumed += packets.count
                            if self.mode != .stalledRenderer { complete(true) }
                        }
                    }, ended: { [weak self] reason in
                        guard let self else { return }
                        self.queue.async {
                            guard !self.finished else { return }
                            switch self.mode {
                            case .normal: precondition(self.consumed == 2 && self.acknowledgements == 2 && reason.message.lowercased().contains("ended"))
                            case .waiting: precondition(self.consumed >= 3 && self.acknowledgements == 2 && self.stateAcknowledgements >= 3)
                            case .stalledRenderer: precondition(self.consumed > 0 && self.acknowledgements == 0 && reason.message.lowercased().contains("stalled"))
                            case .invalidMedia: precondition(self.consumed == 0 && self.acknowledgements == 0 && reason.message.lowercased().contains("invalid"))
                            }
                            self.finish(.success(()))
                        }
                    })
                    self.client = client; client.start()
                } else if case .failed(let error) = state { self.finish(.failure(error)) }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish(.failure(VideoFailure.stalled)) }
        } catch { finish(.failure(error)) }
    }
    private func admit(_ connection: NWConnection, id: UUID, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, eof, error in
            guard let self, !self.finished, self.candidates[id] != nil else { connection.cancel(); return }
            let bytes = buffer + (data ?? Data())
            if bytes.count > 8192 || eof || error != nil { self.candidates.removeValue(forKey: id)?.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else { self.admit(connection, id: id, buffer: bytes); return }
            self.candidates.removeValue(forKey: id)
            guard self.server == nil, String(data: bytes, encoding: .utf8)?.contains("Authorization: Bearer \(self.nonce)\r\n") == true else { connection.cancel(); return }
            self.server = connection
            do { try self.sendFrames(); self.receive() } catch { self.finish(.failure(error)) }
        }
    }
    private func receive() {
        server?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, eof, error in
            guard let self, !self.finished else { return }
            do {
                if let data {
                    try self.parser.append(data) { packet in
                        precondition(packet.header.streamID == self.stream)
                        if packet.header.kind == .stateAcknowledgement { self.stateAcknowledgements += 1 }
                        else { precondition(packet.header.kind == .acknowledgement); self.acknowledgements += 1 }
                    }
                    if self.acknowledgements == 2 {
                        self.server?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                    }
                }
                if !eof && error == nil { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func sendFrames() throws {
        var header = VideoHeader(kind: .h264, streamID: stream, sequence: 1, formatID: 1,
            width: 640, height: 360, contentWidth: 640, contentHeight: 360, keyframe: true, parameterSets: [Data([1]), Data([2])])
        let first = try VideoPacket(header: header, payload: Data(repeating: 101, count: 250_000)).encoded()
        header.sequence = 2; header.keyframe = false; header.parameterSets = []
        let second = try VideoPacket(header: header, payload: Data([1, 2, 3])).encoded()
        if mode == .waiting {
            let header = Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\n\r\n".utf8)
            server?.send(content: header, completion: .contentProcessed { _ in })
            let waiting = try VideoPacket(header: VideoHeader(kind: .state, streamID: stream, state: .waiting)).encoded()
            for index in 0..<6 {
                queue.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                    self?.server?.send(content: waiting, completion: .contentProcessed { _ in })
                }
            }
            queue.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.server?.send(content: first + second, completion: .contentProcessed { _ in })
            }
            return
        }
        let bytes = Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\n\r\n".utf8)
            + (mode == .invalidMedia ? Data(repeating: 255, count: 12) : first + second)
        // A split HTTP header followed by a fragmented frame and coalesced tail.
        server?.send(content: bytes.prefix(17), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish(.failure(error)); return }
            self.server?.send(content: bytes.dropFirst(17), completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(.failure(error)) }
            })
        })
    }
    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        client?.stop(); client = nil
        server?.cancel(); server = nil
        noise?.cancel(); noise = nil
        for candidate in candidates.values { candidate.cancel() }; candidates.removeAll()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        completion(result); retained = nil
    }
}
