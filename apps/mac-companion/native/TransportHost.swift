import CoreWLAN
import Foundation
import Network
import Security

/// Only TLS/peer admission and byte forwarding live here. The Node companion
/// owns APIs, authentication, discovery lifetime, workspaces, and processes.
@main
enum TransportHost {
    // Assigned only on NativeStream.queue; retains the listener until process exit.
    nonisolated(unsafe) private static var listener: StreamListener?
    nonisolated(unsafe) private static var reportedAdmission = false
    // Observations are forwarded to the Node owner's centralized logger.
    // Only closed-schema metadata goes over stdout; never payloads or secrets.
    private static func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.merging(["version": 1]) { _, new in new }) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func main() {
        do { try run() }
        catch {
            emit(["type": "observation", "event": "listener.failed", "fields": ["stage": "setup", "errorDomain": (error as NSError).domain, "errorCode": String((error as NSError).code)]])
            exit(3)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 4,
              let port = NWEndpoint.Port(CommandLine.arguments[2]) else { exit(2) }
        // Watch the lifeline even while interface discovery is waiting. Otherwise
        // a disabled adapter could strand a helper after its owner exits.
        DispatchQueue.global().async {
            while !FileHandle.standardInput.availableData.isEmpty {}
            NativeStream.queue.async {
                Self.listener?.stop()
                // stop() queues teardown on the same serial queue. Flush its
                // bounded summary before exiting; no independent log writer.
                NativeStream.queue.async { exit(0) }
            }
        }
        let identityPath = CommandLine.arguments[1], hostID = CommandLine.arguments[3]
        let parameters = try NativeStream.serverParameters(identity: URL(fileURLWithPath: identityPath))

        // CoreWLAN identifies physical Wi-Fi adapters; no en0/awdl0 assumptions.
        // Exclude them, then admit only scoped link-local Wi-Fi peer sockets.
        // Do not also set requiredInterfaceType = .wifi: with physical
        // Wi-Fi excluded, that prevented AWDL connections in the device A/B test.
        // Interface type and scope are still checked on every accepted socket.
        let physical = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        guard !physical.isEmpty else { exit(4) }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let excluded = path.availableInterfaces.filter { physical.contains($0.name) }
            guard Set(excluded.map(\.name)) == physical else { return }
            monitor.cancel()
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaces = excluded
            do {
                let listener = try StreamListener(parameters: parameters, serviceName: hostID, observe: { observation in
                        emit(["type": "observation", "event": observation.event, "fields": observation.fields])
                        // A failed listener must withdraw readiness and use the
                        // owner's existing helper restart policy, even after start.
                        if observation.event == "listener.failed" { exit(5) }
                    },
                    writeAdmission: true, admit: { connection in
                        let currentPhysical = Set(CWWiFiClient.shared().interfaceNames() ?? [])
                        guard !currentPhysical.isEmpty, let path = connection.currentPath,
                              case .hostPort(.ipv6(let local), _) = path.localEndpoint,
                              case .hostPort(.ipv6(let remote), _) = path.remoteEndpoint,
                              local.isLinkLocal, remote.isLinkLocal,
                              let localInterface = local.interface, let remoteInterface = remote.interface,
                              localInterface == remoteInterface, localInterface.type == .wifi,
                              !currentPhysical.contains(localInterface.name) else { return false }
                        if !Self.reportedAdmission {
                            Self.reportedAdmission = true
                            emit(["type": "observation", "event": "peer.admitted", "fields": ["interfaceName": localInterface.name, "interfaceIndex": String(localInterface.index)]])
                        }
                        return true
                    }, destination: {
                        NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                    })
                listener.start { result in
                    switch result {
                    case .success(let port): emit(["type": "ready", "port": port])
                    case .failure: exit(5)
                    }
                }
                Self.listener = listener

            } catch {
                emit(["type": "observation", "event": "listener.failed", "fields": ["stage": "listener", "errorDomain": (error as NSError).domain, "errorCode": String((error as NSError).code)]])
                exit(5)
            }
        }
        monitor.start(queue: NativeStream.queue)
        dispatchMain()
    }
}
