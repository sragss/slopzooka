import Foundation

@main enum Checks {
    static func main() throws {
        let packets = [Packet(kind: .frame, sequence: 999, body: Data(repeating: 17, count: 100000)), Packet(kind: .ping, sequence: 42)]
        let wire = packets.reduce(Data()) { $0 + $1.encoded() }
        for chunk in [1, 7, 65536] {
            var buffer = PacketBuffer(), received: [Packet] = []
            for offset in stride(from: 0, to: wire.count, by: chunk) {
                received += try buffer.append(wire.subdata(in: offset..<min(wire.count, offset + chunk)))
            }
            precondition(received.count == 2 && received[0].body == packets[0].body)
            precondition(received[0].sequence == 999 && received[1].kind == .ping && received[1].sequence == 42)
            precondition(buffer.data.isEmpty)
        }
        for malformed in [Data([0, 0, 0, 8]), Data([0, 2, 0, 1]), Data([0, 0, 0, 9, 255] + Array(repeating: 0, count: 8))] {
            var buffer = PacketBuffer()
            do { _ = try buffer.append(malformed); fatalError("accepted malformed packet") }
            catch LinkError.invalidPacket { }
        }
        precondition(percentile([4, 1, 3, 2], 0.5) == 2 && percentile([4, 1, 3, 2], 0.95) == 4)
        print("PASS: fragmented/coalesced framing, limits, kind validation, percentiles")

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = try LinkConfig.load(url)
        let host = LinkHost(config: config, peer: false, log: { _ in })
        var client: LinkClient?
        var index = 0
        host.ready = { port in
            func next() {
                guard index < 3 else { host.stop(); print("PASS: wrong pin, wrong token, mode mismatch rejected"); exit(0) }
                let bad = LinkConfig(service: config.service,
                    token: index == 1 ? String(repeating: "0", count: 64) : config.token,
                    fingerprint: index == 0 ? String(repeating: "0", count: 64) : config.fingerprint)
                let c = LinkClient(config: bad, peer: index == 2, condition: "negative-loopback")
                client = c
                var applicationAuthenticated = false
                c.event = { entry in if entry["event"] as? String == "authenticated" { applicationAuthenticated = true } }
                c.complete = { success in
                    precondition(!success && !applicationAuthenticated)
                    index += 1; next()
                }
                c.start(direct: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!))
            }
            next()
        }
        try host.start(identity: url.deletingLastPathComponent().appendingPathComponent("identity.p12"), loopback: true)
        linkQueue.asyncAfter(deadline: .now() + 25) { print("FAIL: negative tests timed out"); exit(1) }
        withExtendedLifetime((host, client)) { dispatchMain() }
    }
}
