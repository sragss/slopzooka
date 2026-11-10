import Foundation
import Network
import Security
import CryptoKit

// Disposable link experiment. No app content, screen access, or production routes.
let linkQueue = DispatchQueue(label: "slz.peer-link")
let serviceType = "_slz-link._tcp"
func clockNow() -> Double { ProcessInfo.processInfo.systemUptime }
func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)]
}

struct LinkConfig: Codable {
    let service: String
    let token: String
    let fingerprint: String
    static func load(_ url: URL) throws -> LinkConfig {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.token.count == 64, value.fingerprint.count == 64,
              value.token.allSatisfy({ $0.isHexDigit }), value.fingerprint.allSatisfy({ $0.isHexDigit }),
              !value.service.isEmpty else { throw LinkError.invalidConfig }
        return value
    }
}
enum LinkError: Error { case invalidConfig, invalidPacket, identity }
enum Kind: UInt8 { case auth = 1, ready, frame, ping, pong, phase, end, report, saved }
struct Packet {
    let kind: Kind
    var sequence: UInt64 = 0
    var body = Data()
    func encoded() -> Data {
        var size = UInt32(9 + body.count).bigEndian
        var seq = sequence.bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(kind.rawValue)
        data.append(withUnsafeBytes(of: &seq) { Data($0) })
        data.append(body)
        return data
    }
}
struct PacketBuffer {
    var data = Data()
    mutating func append(_ bytes: Data) throws -> [Packet] {
        data.append(bytes)
        guard data.count <= 262144 else { throw LinkError.invalidPacket }
        var packets: [Packet] = []
        while data.count >= 4 {
            let size = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (9...131072).contains(size) else { throw LinkError.invalidPacket }
            guard data.count >= size + 4 else { break }
            let part = Data(data.dropFirst(4).prefix(size))
            guard let kind = Kind(rawValue: part[0]) else { throw LinkError.invalidPacket }
            let seq = part[1..<9].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            packets.append(Packet(kind: kind, sequence: seq, body: Data(part.dropFirst(9))))
            data = Data(data.dropFirst(size + 4))
        }
        return packets
    }
}
func pathInfo(_ path: NWPath?) -> [String: Any] {
    guard let path else { return ["status": "missing"] }
    // availableInterfaces is not a list of proven selected interfaces. Keep raw
    // endpoints and used types too; never infer direct radio from the opt-in flag.
    let types: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .loopback, .cellular, .other]
    return ["status": String(describing: path.status),
            "availableInterfaces": path.availableInterfaces.map { ["name": $0.name, "type": String(describing: $0.type)] },
            "usedTypes": types.filter { path.usesInterfaceType($0) }.map { String(describing: $0) },
            "local": path.localEndpoint.map { String(describing: $0) } ?? "unknown",
            "remote": path.remoteEndpoint.map { String(describing: $0) } ?? "unknown",
            "expensive": path.isExpensive, "constrained": path.isConstrained]
}
func parameters(_ config: LinkConfig, peer: Bool, identityURL: URL? = nil) throws -> NWParameters {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    if let identityURL {
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: identityURL) as CFData,
                                    [kSecImportExportPassphrase as String: "probe-local-only",
                                     kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess, let item = (items as? [[String: Any]])?.first,
              let raw = item[kSecImportItemIdentity as String] else { throw LinkError.identity }
        let identity = raw as! SecIdentity
        guard let converted = sec_identity_create(identity) else { throw LinkError.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, converted)
    } else {
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first else { complete(false); return }
            let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
            complete(hash == config.fingerprint)
        }, linkQueue)
    }
    let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
    let p = NWParameters(tls: tls, tcp: tcp)
    p.includePeerToPeer = peer
    return p
}

// All callbacks and mutable state stay on linkQueue, including deadlines.
final class Channel {
    let connection: NWConnection
    var onPacket: ((Packet) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?
    var onPath: (([String: Any]) -> Void)?
    private var buffer = PacketBuffer()
    private(set) var closed = false
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onReady?(); self.read()
            case .failed(let error): self.close("network: \(error)")
            case .waiting(let error): self.onPath?(["waiting": String(describing: error)])
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] path in self?.onPath?(pathInfo(path)) }
        connection.betterPathUpdateHandler = { [weak self] better in self?.onPath?(["betterPathAvailable": better]) }
        connection.start(queue: linkQueue)
    }
    func send(_ packet: Packet, completion: ((Bool) -> Void)? = nil) {
        guard !closed else { completion?(false); return }
        connection.send(content: packet.encoded(), completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send: \(error)") }
            completion?(error == nil)
        })
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
            guard let self, !self.closed else { return }
            do {
                if let bytes { for packet in try self.buffer.append(bytes) { if !self.closed { self.onPacket?(packet) } } }
                if done || error != nil { self.close("remote closed: \(String(describing: error))") }
                else { self.read() }
            } catch { self.close("invalid packet") }
        }
    }
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true; connection.cancel(); onClose?(reason)
        onPacket = nil; onReady = nil; onClose = nil; onPath = nil
    }
}
