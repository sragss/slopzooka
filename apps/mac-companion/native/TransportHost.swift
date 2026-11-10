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
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let port = NWEndpoint.Port(CommandLine.arguments[2]) else { exit(2) }
        // Watch the lifeline even while interface discovery is waiting. Otherwise
        // a disabled adapter could strand a helper after its owner exits.
        DispatchQueue.global().async {
            while !FileHandle.standardInput.availableData.isEmpty {}
            exit(0)
        }
        let identityPath = CommandLine.arguments[1], hostID = CommandLine.arguments[3]
        let parameters = try NativeStream.serverParameters(identity: URL(fileURLWithPath: identityPath))

        // CoreWLAN identifies physical Wi-Fi adapters; no en0/awdl0 assumptions.
        // Exclude them and every non-Wi-Fi type, then independently check each
        // accepted socket's scoped link-local endpoints before forwarding bytes.
        let physical = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        guard !physical.isEmpty else { exit(4) }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let excluded = path.availableInterfaces.filter { physical.contains($0.name) }
            guard Set(excluded.map(\.name)) == physical else { return }
            monitor.cancel()
            parameters.includePeerToPeer = true
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaces = excluded
            do {
                let listener = try StreamListener(parameters: parameters, serviceName: hostID,
                    writeAdmission: true, admit: { connection in
                        let currentPhysical = Set(CWWiFiClient.shared().interfaceNames() ?? [])
                        guard !currentPhysical.isEmpty, let path = connection.currentPath,
                              case .hostPort(.ipv6(let local), _) = path.localEndpoint,
                              case .hostPort(.ipv6(let remote), _) = path.remoteEndpoint,
                              local.isLinkLocal, remote.isLinkLocal,
                              let localInterface = local.interface, let remoteInterface = remote.interface,
                              localInterface == remoteInterface, localInterface.type == .wifi,
                              !currentPhysical.contains(localInterface.name) else { return false }
                        return true
                    }, destination: {
                        NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                    })
                listener.start { result in
                    switch result {
                    case .success(let port): print("{\"ready\":true,\"port\":\(port)}"); fflush(stdout)
                    case .failure: exit(5)
                    }
                }
                Self.listener = listener

            } catch { exit(5) }
        }
        monitor.start(queue: NativeStream.queue)
        dispatchMain()
    }
}
