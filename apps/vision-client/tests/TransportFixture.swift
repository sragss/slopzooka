import Foundation
import Network

/// Disposable integration driver; never links into either app.
@main
struct TransportFixture {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let remote = URL(string: args[1])!, token = args[2]
        if args.count == 4, args[3] == "client" {
            let suite = "TransportFixture.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var values: [String: String] = [:]
            let credentials = CompanionCredentials(read: { values[$0] }, write: { values[$0] = $1 })
            try credentials.pair(remote, hostID: "fixture", token: token)
            let diagnostics = NativeDiagnostics()
            let client = CompanionClient(defaults: defaults, credentials: credentials, diagnostics: diagnostics)
            client.host = remote.absoluteString
            guard await client.connect(), await client.connect() else { throw URLError(.cannotConnectToHost) }
            _ = try await client.sessions(hostID: "fixture")
            // Deliver a failed batch, then retry the same identities on the
            // route-owned native adapter. Successful idle flushes stay silent.
            await Task.yield()
            await client.flushDiagnostics()
            await client.flushDiagnostics()
            await Task.yield()
            await client.flushDiagnostics()
            precondition(diagnostics.pendingCount == 0)
            for _ in 0..<3 { await client.flushDiagnostics() }
            precondition(diagnostics.pendingCount == 0)
            let endpoint = try client.endpoint(for: "fixture")
            print("{\"url\":\"\(endpoint.absoluteString)\"}"); fflush(stdout)
            return
        }
        var ingress: StreamListener?
        var peerEndpoint: NWEndpoint?
        var authority: Data?
        if args.count > 3 {
            let parameters = try NativeStream.serverParameters(identity: URL(fileURLWithPath: args[3]))
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let targetPort = NWEndpoint.Port(rawValue: UInt16(remote.port!))!
            let server = try StreamListener(parameters: parameters, writeAdmission: true) {
                NWConnection(host: "127.0.0.1", port: targetPort, using: .tcp)
            }
            ingress = server
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                server.start { continuation.resume(with: $0) }
            }
            peerEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            authority = try Data(contentsOf: URL(fileURLWithPath: args[4]))
        }
        let observe: StreamObservation.Sink = { observation in
            let data = try! JSONSerialization.data(withJSONObject: ["event": observation.event, "fields": observation.fields])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        func open() async throws -> CompanionTransportRoute {
            if let peerEndpoint, let authority {
                return try await CompanionTransportRoute.direct(endpoint: peerEndpoint, authority: authority, token: token, observe: observe)
            }
            return try await CompanionTransportRoute.localNetwork(remote, token: token, observe: observe)
        }
        var route = try await open()
        func report() { print("{\"url\":\"\(route.endpoint.absoluteString)\"}"); fflush(stdout) }
        report()
        for try await command in FileHandle.standardInput.bytes.lines {
            if command == "stop" {
                route.stop()
                do { _ = try await route.exchange(URLRequest(url: route.endpoint)); preconditionFailure("Retired route must reject sends") }
                catch { precondition((error as? URLError)?.code == .cancelled) }
                print("{\"stopped\":true}"); fflush(stdout) }
            if command == "restart" { route.stop(); route = try await open(); report() }
        }
        route.stop()
        ingress?.stop()
    }
}
