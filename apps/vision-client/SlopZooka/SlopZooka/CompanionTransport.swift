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
    }
    private static var origins: [String: Origin] = [:]
    private let id = UUID()
    private let session = URLSession(configuration: .ephemeral)
    let endpoint: URL
    private let listener: StreamListener?

    private init(endpoint: URL, listener: StreamListener?, token: String?) {
        self.endpoint = endpoint
        self.listener = listener
        Self.origins[Self.key(endpoint)] = Origin(id: id, token: token)
    }

    private static func key(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "http")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    private var nativeChannels: [UUID: NWConnection] = [:]
    func windowChannel(id: UUID, sourceID: String) throws -> (NWConnection, Data) {
        let parts = sourceID.split(separator: ":")
        guard parts.count == 4, parts[0] == "window", UUID(uuidString: String(parts[1])) != nil,
              UInt32(parts[2]) != nil, UInt32(parts[3]) != nil else { throw URLError(.badURL) }
        guard !stopped, nativeChannels.count < 8, let host = endpoint.host,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)) ?? 0),
              let token = Self.token(for: endpoint) else { throw URLError(.cannotConnectToHost) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: endpoint.scheme == "https" ? .tls : .tcp)
        nativeChannels[id]?.cancel()
        nativeChannels[id] = connection
        let request = "GET /api/window-stream/\(sourceID) HTTP/1.1\r\nHost: \(host):\(port.rawValue)\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\nAuthorization: Bearer \(token)\r\n\r\n"
        return (connection, Data(request.utf8))
    }
    func releaseWindowChannel(id: UUID) { nativeChannels.removeValue(forKey: id)?.cancel() }
    private var stopped = false
    func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard !stopped, let url = request.url, Self.key(url) == Self.key(endpoint) else { throw URLError(.cancelled) }
        return try await session.data(for: request)
    }

    static func token(for url: URL) -> String? { origins[key(url)]?.token }

    func stop() {
        guard !stopped else { return }
        stopped = true
        session.invalidateAndCancel()
        for connection in nativeChannels.values { connection.cancel() }
        nativeChannels.removeAll()
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

    static func localNetwork(_ url: URL, token: String?, observe: @escaping StreamObservation.Sink = { _ in }) async throws -> CompanionTransportRoute {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue > 0 else { throw URLError(.badURL) }
        return try await open(token: token, observe: observe) {
            NWConnection(host: NWEndpoint.Host(host), port: port, using: url.scheme == "https" ? .tls : .tcp)
        }
    }

    static func direct(hostID: String, authority: Data, token: String, observe: @escaping StreamObservation.Sink = { _ in }) async throws -> CompanionTransportRoute {
        let endpoint = try await PeerDiscovery.find(hostID: hostID)
        return try await direct(endpoint: endpoint, authority: authority, token: token, observe: observe)
    }

    static func direct(endpoint: NWEndpoint, authority: Data, token: String, observe: @escaping StreamObservation.Sink = { _ in }) async throws -> CompanionTransportRoute {
        return try await open(token: token, readAdmission: true, observe: observe) {
            NWConnection(to: endpoint, using: try NativeStream.clientParameters(authority: authority))
        }
    }

    private static func open(token: String?, readAdmission: Bool = false, observe: @escaping StreamObservation.Sink,
                             destination: @escaping @Sendable () throws -> NWConnection) async throws -> CompanionTransportRoute {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try StreamListener(parameters: parameters, observe: observe, readAdmission: readAdmission, destination: destination)
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
