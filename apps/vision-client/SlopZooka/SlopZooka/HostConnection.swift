import Foundation

/// Discovery offers candidates; a successful endpoint stays selected until explicitly changed.
@MainActor
final class HostConnection {
    private(set) var hostID: String?
    private(set) var endpoint: URL?

    func accept(_ health: CompanionHealthResponse, endpoint: URL) throws {
        guard health.protocolVersion == 1 else {
            throw CompanionError(message: "Update the companion and headset app together")
        }
        self.hostID = health.hostId
        self.endpoint = endpoint
    }

    func shouldTry(_ candidate: String) -> Bool {
        endpoint == nil || CompanionAPI.baseURL(host: candidate)?.host == endpoint?.host
    }
}
