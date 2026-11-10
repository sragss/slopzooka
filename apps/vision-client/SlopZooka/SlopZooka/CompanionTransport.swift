import Foundation
import Network

enum ConnectionMethod: String, CaseIterable, Identifiable {
    case localNetwork, direct
    var id: String { rawValue }
    var title: String { self == .direct ? "Direct to Mac" : "Local Network" }
}

/// One accepted route owns its loopback origin and all native byte channels.
/// URLs and credentials are ephemeral; neither is part of a saved window.
@MainActor
final class CompanionTransportRoute {
    private struct Origin {
        let id: UUID
        let token: String?
        let session: URLSession
    }
    private static var origins: [String: Origin] = [:]
    private let id = UUID()
    private let session = URLSession(configuration: .ephemeral)
    let endpoint: URL
    private let listener: StreamListener?

    private init(endpoint: URL, listener: StreamListener?, token: String?) {
        self.endpoint = endpoint
        self.listener = listener
        Self.origins[Self.key(endpoint)] = Origin(id: id, token: token, session: session)
    }

    private static func key(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "http")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    static func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let origin = origins[key(url)] else { throw URLError(.cancelled) }
        return try await origin.session.data(for: request)
    }

    static func token(for url: URL) -> String? { origins[key(url)]?.token }

    func stop() {
        session.invalidateAndCancel()
        // A renewed legacy route may have the same origin as its predecessor.
        // Retiring that predecessor must not revoke the new route's credential.
        if Self.origins[Self.key(endpoint)]?.id == id {
            Self.origins.removeValue(forKey: Self.key(endpoint))
        }
        listener?.stop()
    }

    static func legacyLocalNetwork(_ url: URL, token: String?) -> CompanionTransportRoute {
        CompanionTransportRoute(endpoint: url, listener: nil, token: token)
    }

    static func localNetwork(_ url: URL, token: String?) async throws -> CompanionTransportRoute {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue > 0 else { throw URLError(.badURL) }
        return try await open(token: token) {
            NWConnection(host: NWEndpoint.Host(host), port: port, using: url.scheme == "https" ? .tls : .tcp)
        }
    }

    static func direct(hostID: String, authority: Data, token: String) async throws -> CompanionTransportRoute {
        let endpoint = try await PeerDiscovery.find(hostID: hostID)
        return try await direct(endpoint: endpoint, authority: authority, token: token)
    }

    static func direct(endpoint: NWEndpoint, authority: Data, token: String) async throws -> CompanionTransportRoute {
        return try await open(token: token, readAdmission: true) {
            NWConnection(to: endpoint, using: try NativeStream.clientParameters(authority: authority))
        }
    }

    private static func open(token: String?, readAdmission: Bool = false,
                             destination: @escaping @Sendable () throws -> NWConnection) async throws -> CompanionTransportRoute {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try StreamListener(parameters: parameters, readAdmission: readAdmission, destination: destination)
        do {
            let port: UInt16 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in listener.start { continuation.resume(with: $0) } }
            } onCancel: { listener.stop() }
            try Task.checkCancellation()
            guard let endpoint = URL(string: "http://127.0.0.1:\(port)") else { throw URLError(.badURL) }
            return CompanionTransportRoute(endpoint: endpoint, listener: listener, token: token)
        } catch { listener.stop(); throw error }
    }
}

/// Bounded browsing; always stop the radio browse before opening a connection.
/// State is confined to NativeStream.queue, including task cancellation.
nonisolated private final class PeerDiscovery: @unchecked Sendable {
    private let browser: NWBrowser
    private var completion: CheckedContinuation<NWEndpoint, Error>?
    private var cancelled = false
    private let hostID: String

    private init(hostID: String) {
        self.hostID = hostID
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: NativeStream.serviceType, domain: "local."), using: parameters)
    }

    static func find(hostID: String) async throws -> NWEndpoint {
        let discovery = PeerDiscovery(hostID: hostID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                NativeStream.queue.async { discovery.start(continuation) }
            }
        } onCancel: { NativeStream.queue.async { discovery.cancelled = true; discovery.finish(.failure(URLError(.cancelled))) } }
    }

    private func start(_ continuation: CheckedContinuation<NWEndpoint, Error>) {
        completion = continuation
        guard !cancelled else { finish(.failure(URLError(.cancelled))); return }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name == self.hostID {
                    self.finish(.success(result.endpoint)); return
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.finish(.failure(error)) }
        }
        browser.start(queue: NativeStream.queue)
        NativeStream.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(.failure(URLError(.cannotFindHost)))
        }
    }

    private func finish(_ result: Result<NWEndpoint, Error>) {
        guard let completion else { return }
        self.completion = nil
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
        completion.resume(with: result)
    }
}
