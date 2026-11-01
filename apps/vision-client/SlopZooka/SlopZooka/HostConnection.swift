import Foundation

struct ConnectedHost: Equatable {
    let id: String
    let endpoint: URL
}

/// Discovery offers candidates; a successful endpoint stays selected until explicitly changed.
@MainActor
final class HostConnection {
    private(set) var current: ConnectedHost?

    func accept(_ health: CompanionHealthResponse, endpoint: URL) throws {
        guard health.protocolVersion == 1 else {
            throw CompanionError(message: "Update the companion and headset app together")
        }
        current = ConnectedHost(id: health.hostId, endpoint: endpoint)
    }
}
