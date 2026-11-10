import Foundation
import Network

@main enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("link-probe host|client|selftest CONFIG [--peer] [--condition LABEL]")
            exit(2)
        }
        let configURL = URL(fileURLWithPath: args[2])
        let config = try LinkConfig.load(configURL)
        let peer = args.contains("--peer")
        let condition = args.firstIndex(of: "--condition").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "unspecified"
        let log: ([String: Any]) -> Void = { entry in
            var row = entry; row["wallTime"] = ISO8601DateFormatter().string(from: Date())
            print(String(decoding: json(row), as: UTF8.self)); fflush(stdout)
        }
        let host = LinkHost(config: config, peer: peer, log: log)
        let client = LinkClient(config: config, peer: peer, condition: condition)
        client.event = log
        client.complete = { success in host.stop(); exit(success ? 0 : 1) }
        let identity = configURL.deletingLastPathComponent().appendingPathComponent("identity.p12")
        switch args[1] {
        case "host": try host.start(identity: identity)
        case "client": linkQueue.async { client.start() }
        case "selftest":
            host.ready = { port in client.start(direct: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)) }
            try host.start(identity: identity, loopback: true)
        default: exit(2)
        }
        // Retain owners for the process lifetime; no system/network reconfiguration.
        withExtendedLifetime((host, client)) { dispatchMain() }
    }
}
