import Combine
import Darwin
import Foundation
import Security

/// Owns Mac discovery, selection, pairing, refreshes, and native control transport.
/// Window intent and process lifetime stay with their domain owners.
@MainActor
final class CompanionClient: NSObject, ObservableObject {
    typealias Exchange = @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private let exchange: Exchange
    private let defaults: UserDefaults
    private let credentials: CompanionCredentials
    private let diagnostics: NativeDiagnostics
    private let log: AppLog
    private var diagnosticsPoll: Task<Void, Never>?
    private var sendingDiagnostics = false
    private struct Route: Equatable {
        let endpoint: URL
        let revision = UUID()
        let health: CompanionHealthResponse
        let paired: Bool
    }
    private var routes: [String: Route] = [:]
    private var selection = UUID()
    private var currentRoute: Route? { current.flatMap { routes[$0.id] } }

    init(defaults: UserDefaults = .standard, credentials: CompanionCredentials? = nil, diagnostics: NativeDiagnostics? = nil, exchange: @escaping Exchange = { try await URLSession.shared.data(for: $0) }) {
        self.exchange = exchange
        self.defaults = defaults
        self.credentials = credentials ?? .live
        self.diagnostics = diagnostics ?? .shared
        self.log = AppLog("network", diagnostics: self.diagnostics)
        super.init()
        browser.delegate = self
    }

    deinit {
        diagnosticsPoll?.cancel()
        sessionPoll?.cancel()
        for task in frontendPolls.values { task.cancel() }
    }

    @Published var host = ""
    @Published var pairingCode = ""
    @Published private(set) var current: ConnectedHost?
    @Published private(set) var needsPairing = false
    @Published private(set) var isPairing = false
    @Published private(set) var pairingError: String?
    @Published private(set) var healthState: HealthState = .idle
    @Published private(set) var companions: [DiscoveredCompanion] = []
    @Published private(set) var discoveryError: String?
    @Published private var frontendCatalogs: [String: FrontendCatalog] = [:]
    var onConnected: ((ConnectedHost) -> Void)?
    var onSessionSnapshot: ((HostSessionsResponse, ConnectedHost) async -> Void)?
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var sessionPoll: Task<Void, Never>?
    private var frontendPolls: [String: Task<Void, Never>] = [:]
    private var refreshingFrontends: [String: UUID] = [:]
    private var connecting = false
    private var refreshingSessions: [String: (route: UUID, request: UUID)] = [:]
    private var pendingHosts: [String] = []
    var normalizedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var health: CompanionHealthResponse? { currentRoute?.health }
    var knownHostIDs: Set<String> { Set(routes.keys) }
    // URL access is limited to content adapters; control callers address the host.
    func endpoint(for hostID: String) throws -> URL { try route(for: hostID).endpoint }
    private func route(for hostID: String) throws -> Route {
        guard let route = routes[hostID] else { throw URLError(.cannotFindHost) }
        return route
    }
    var isReady: Bool {
        if case .success = healthState { return !needsPairing }
        return false
    }

    // App lifetime: any restored scene can start discovery and recovery.
    func start() {
        guard sessionPoll == nil else { return }
        host = defaults.string(forKey: "companionHost") ?? ""
        browser.searchForServices(ofType: "_slopzooka._tcp.", inDomain: "local.")
        sessionPoll = poll { client in
            if client.current == nil { await client.maybeAutoConnect(candidateHosts: []) }
            else { await client.refreshSessions() }
        }
        for hostID in knownHostIDs { startFrontendPoll(hostID: hostID) }
    }

    private func poll(_ action: @escaping @MainActor (CompanionClient) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                if let self { await action(self) } else { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func startFrontendPoll(hostID: String) {
        frontendPolls[hostID]?.cancel()
        frontendPolls[hostID] = poll { await $0.refreshFrontends(hostID: hostID) }
    }

    func accept(_ health: CompanionHealthResponse, endpoint: URL, authenticated: Bool) throws {
        guard health.protocolVersion == 1 else {
            throw CompanionError(message: "Update the companion and headset app together")
        }
        frontendCatalogs.removeValue(forKey: health.hostId)
        refreshingFrontends.removeValue(forKey: health.hostId)
        selection = UUID()
        let route = Route(endpoint: endpoint, health: health, paired: authenticated)
        routes[health.hostId] = route
        let target = ConnectedHost(id: health.hostId, revision: route.revision)
        current = target
        needsPairing = !authenticated
        healthState = .success
        diagnostics.bind(to: health.hostId)
        log.info("connection.accepted", ["hostId": health.hostId, "paired": String(authenticated)])
        if authenticated && health.diagnosticsVersion == 1 && diagnosticsPoll == nil {
            diagnosticsPoll = poll { await $0.flushDiagnostics() }
        }
        onConnected?(target)
        if sessionPoll != nil { startFrontendPoll(hostID: health.hostId) }
    }

    func select(_ address: String) async {
        host = address
        pairingCode = ""
        pairingError = nil
        await connect()
    }

    func maybeAutoConnect(candidateHosts: [String]) async {
        let candidates = connecting ? candidateHosts : [normalizedHost] + candidateHosts
        for candidate in candidates where !candidate.isEmpty && !pendingHosts.contains(candidate) {
            if connecting && candidate == normalizedHost { continue }
            pendingHosts.append(candidate)
        }
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        while !pendingHosts.isEmpty {
            let candidate = pendingHosts.removeFirst()
            if current != nil {
                pendingHosts.removeAll()
                return
            }
            host = candidate
            if await connect() || host != candidate {
                pendingHosts.removeAll()
                return
            }
        }
    }

    @discardableResult
    func connect() async -> Bool {
        selection = UUID()
        let attempt = selection
        guard let base = Self.baseURL(host: normalizedHost) else {
            healthState = .failure("Enter a valid companion host")
            return false
        }
        needsPairing = false
        pairingError = nil
        healthState = .checking
        do {
            let health: CompanionHealthResponse = try await request(base: base, path: "/health", timeout: 4)
            guard !Task.isCancelled, selection == attempt else { return false }
            let authenticated = health.paired && credentials.token(for: base) != nil
            if authenticated { try credentials.migrate(base, hostID: health.hostId) }
            try accept(health, endpoint: base, authenticated: authenticated)
            let accepted = current
            defaults.set(normalizedHost, forKey: "companionHost")
            if !needsPairing {
                async let sessions: Void = refreshSessions()
                await refreshFrontends(hostID: health.hostId)
                await sessions
            }
            return current == accepted
        } catch {
            guard !Task.isCancelled, selection == attempt else { return false }
            let message = "\(base.absoluteString)\n\(error.localizedDescription)"
            healthState = currentRoute?.endpoint == base ? .reconnecting(message) : .failure(message)
            return false
        }
    }

    func pair() async {
        guard !isPairing, needsPairing, pairingCode.count == 6,
            pairingCode.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let base = currentRoute?.endpoint else { return }
        let attempt = selection
        isPairing = true
        pairingError = nil
        defer { isPairing = false }
        do {
            struct PairResponse: Decodable {
                let token: String
                let hostId: String
            }
            let response: PairResponse = try await request(base: base, path: "/api/pair", method: "POST",
                body: Self.json(["code": pairingCode]))
            guard !Task.isCancelled, selection == attempt else { return }
            try credentials.pair(base, hostID: response.hostId, token: response.token)
            await select(base.absoluteString)
        } catch {
            guard !Task.isCancelled, selection == attempt else { return }
            pairingCode = ""
            pairingError = "\(base.absoluteString)\n\(error.localizedDescription)"
        }
    }

    func captureBugReport(hostID: String, around: String) async throws -> String {
        await flushDiagnostics()
        struct Capture: Decodable { let reportId: String }
        let result: Capture = try await request(hostID: hostID, path: "/api/diagnostics/capture", method: "POST",
            body: Self.json(["around": around]), timeout: 30)
        return result.reportId
    }

    func prepareBugReport(hostID: String, title: String, description: String, around: String, reportID: String?) async throws -> BugReportDraft {
        var body = ["title": title, "description": description, "around": around]
        if let reportID { body["reportId"] = reportID }
        let draft: BugReportDraft = try await request(hostID: hostID, path: "/api/diagnostics/bug-report/prepare", method: "POST",
            body: Self.json(body), timeout: 30)
        if let url = draft.browserURL, !BugReportDraft.isComposer(url) { throw URLError(.badURL) }
        return draft
    }

    func submitBugReport(hostID: String, draftID: String) async throws -> URL {
        struct Issue: Decodable { let url: URL }
        let result: Issue = try await request(hostID: hostID, path: "/api/diagnostics/bug-report/submit", method: "POST",
            body: Self.json(["draftId": draftID]), timeout: 40)
        guard result.url.absoluteString.range(of: #"^https://github\.com/sragss/slopzooka/issues/[0-9]+$"#, options: .regularExpression) != nil
        else { throw URLError(.badURL) }
        return result.url
    }

    func showConnectionCode() async {
        guard needsPairing, let base = currentRoute?.endpoint else { return }
        // Optional convenience: older companions still expose their code in the menu.
        let _: APIAcknowledgement? = try? await request(base: base, path: "/api/pair/display", method: "POST", timeout: 4)
    }

    func refreshSessions(hostID: String? = nil, force: Bool = false) async {
        guard let id = hostID ?? current?.id, let route = routes[id], route.paired,
            current?.id != id || !needsPairing,
            force || refreshingSessions[id]?.route != route.revision else { return }
        let target = ConnectedHost(id: id, revision: route.revision)
        let attempt = selection, request = UUID()
        refreshingSessions[id] = (target.revision, request)
        defer { if refreshingSessions[id]?.request == request { refreshingSessions[id] = nil } }
        if let sessions = try? await sessions(hostID: id) {
            guard !Task.isCancelled, routes[id]?.revision == target.revision,
                hostID != nil || (current == target && selection == attempt),
                refreshingSessions[id]?.request == request else { return }
            await onSessionSnapshot?(sessions, target)
        }
    }

    func frontends(for hostID: String?) -> FrontendCatalog {
        hostID.flatMap { frontendCatalogs[$0] } ?? FrontendCatalog(frontends: [], warning: nil)
    }

    // All views of one Mac share its catalog. Mutations supersede an older read.
    func refreshFrontends(hostID: String, force: Bool = false) async {
        guard !Task.isCancelled, let route = routes[hostID], route.paired,
            current?.id != hostID || !needsPairing,
            force || refreshingFrontends[hostID] == nil else { return }
        let requestID = UUID()
        refreshingFrontends[hostID] = requestID
        defer { if refreshingFrontends[hostID] == requestID { refreshingFrontends.removeValue(forKey: hostID) } }
        do {
            let catalog: FrontendCatalog = try await request(hostID: hostID, path: "/api/frontends")
            guard !Task.isCancelled, routes[hostID] == route, refreshingFrontends[hostID] == requestID else { return }
            frontendCatalogs[hostID] = catalog
        } catch {
            guard !Task.isCancelled, routes[hostID] == route, refreshingFrontends[hostID] == requestID else { return }
            frontendCatalogs[hostID] = FrontendCatalog(frontends: frontends(for: hostID).frontends, warning: error.localizedDescription)
        }
    }

    func sessions(hostID: String) async throws -> HostSessionsResponse {
        try await request(hostID: hostID, path: "/api/sessions")
    }
    func repositories(hostID: String) async throws -> RecentReposResponse {
        try await request(hostID: hostID, path: "/api/repos/recent?limit=30")
    }
    func workspaces(hostID: String) async throws -> RecentWorkspacesResponse {
        try await request(hostID: hostID, path: "/api/workspaces?limit=100")
    }
    func owners(hostID: String) async throws -> AvailableOwnersResponse {
        try await request(hostID: hostID, path: "/api/owners")
    }
    func launchWorkspace(hostID: String, nameWithOwner: String, profile: String?) async throws -> LaunchWorkspaceResponse {
        try await request(hostID: hostID, path: "/api/workspaces/launch", method: "POST",
            body: Self.json(["nameWithOwner": nameWithOwner, "profile": profile]), timeout: 300)
    }
    func createRepository(hostID: String, owner: String, name: String, isPrivate: Bool, profile: String?) async throws -> LaunchWorkspaceResponse {
        try await request(hostID: hostID, path: "/api/repos/create-and-launch", method: "POST",
            body: Self.json(["owner": owner, "repoName": name, "visibility": isPrivate ? "private" : "public", "profile": profile]), timeout: 300)
    }
    func reopenWorkspace(hostID: String, id: String, profile: String?) async throws -> LaunchWorkspaceResponse {
        try await request(hostID: hostID, path: "/api/workspaces/\(id)/reopen", method: "POST",
            body: Self.json(["profile": profile as Any? ?? NSNull()]))
    }
    func archiveWorkspace(hostID: String, id: String) async throws {
        let _: ArchiveWorkspaceResponse = try await request(hostID: hostID, path: "/api/workspaces/\(id)/archive", method: "POST")
    }
    func pruneMissingWorkspaces(hostID: String) async throws -> PruneMissingWorkspacesResponse {
        try await request(hostID: hostID, path: "/api/workspaces/prune-missing", method: "POST")
    }
    func launchSession(hostID: String, workspaceID: String, sessionID: String, profile: String?) async throws -> CreatedSessionResponse {
        try await request(hostID: hostID, path: "/api/workspaces/\(workspaceID)/sessions", method: "POST",
            body: Self.json(["sessionId": sessionID, "profile": profile as Any? ?? NSNull()]))
    }
    func renameWorkspace(hostID: String, id: String, name: String) async throws {
        let _: ArchiveWorkspaceResponse = try await request(hostID: hostID, path: "/api/workspaces/\(id)", method: "PATCH",
            body: Self.json(["name": name]))
    }
    func renameSession(hostID: String, id: String, name: String) async throws -> CreatedSessionResponse {
        try await request(hostID: hostID, path: "/api/sessions/\(id)", method: "PATCH",
            body: Self.json(["name": name]))
    }
    func endSession(hostID: String, id: String) async throws {
        let _: APIAcknowledgement = try await request(hostID: hostID, path: "/api/sessions/\(id)", method: "DELETE")
    }
    func submitInput(hostID: String, sessionID: String, commandID: String, text: String) async throws {
        let _: APIAcknowledgement = try await request(hostID: hostID, path: "/api/sessions/\(sessionID)/input", method: "POST",
            body: Self.json(["commandId": commandID, "text": text, "sendReturn": true]))
    }
    func windowLayout(hostID: String) async throws -> WindowLayout {
        try await request(hostID: hostID, path: "/api/window-layout")
    }
    func saveWindowLayout(hostID: String, layout: WindowLayout) async throws -> WindowLayout {
        try await request(hostID: hostID, path: "/api/window-layout", method: "PUT", body: JSONEncoder().encode(layout))
    }
    func openFrontend(hostID: String, id: String) async throws -> OpenFrontendResponse {
        try await request(hostID: hostID, path: "/api/frontends/open", method: "POST",
            body: Self.json(["id": id]))
    }
    func addFrontend(hostID: String, url: String) async throws {
        let _: OpenFrontendResponse = try await request(hostID: hostID, path: "/api/frontends", method: "POST",
            body: Self.json(["url": url]))
        await refreshFrontends(hostID: hostID, force: true)
    }
    func removeFrontend(hostID: String, id: String) async throws {
        let _: APIAcknowledgement = try await request(hostID: hostID, path: "/api/frontends/\(id)", method: "DELETE")
        await refreshFrontends(hostID: hostID, force: true)
    }

    private static func json(_ values: [String: Any?]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values.compactMapValues { $0 }, options: .sortedKeys)
    }

    private static let clientID: String = {
        let key = "companionClientID"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static func baseURL(host: String) -> URL? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value.contains("://") ? value : "http://\(value)"),
            url.host != nil, url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    static func authorized(_ request: URLRequest) -> URLRequest { authorized(request, credentials: .live) }
    private static func authorized(_ request: URLRequest, credentials: CompanionCredentials) -> URLRequest {
        var request = request
        request.setValue(clientID, forHTTPHeaderField: "X-SlopZooka-Client-ID")
        if let url = request.url, let token = credentials.token(for: url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func request<T: Decodable>(
        hostID: String, path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20
    ) async throws -> T {
        let route = try route(for: hostID)
        let attempt = selection
        guard route.paired else { throw CompanionError(message: "Pair with this Mac first", statusCode: 401) }
        do {
            let result: T = try await request(base: route.endpoint, path: path, hostID: hostID, method: method, body: body, timeout: timeout)
            guard routes[hostID] == route else { throw URLError(.cancelled) }
            if current?.id == hostID, selection == attempt, !needsPairing {
                if case .reconnecting = healthState { healthState = .success }
            }
            return result
        } catch {
            guard routes[hostID] == route else { throw URLError(.cancelled) }
            if current?.id == hostID, selection == attempt {
                if (error as? CompanionError)?.statusCode == 401 { needsPairing = true }
                else if let network = error as? URLError, network.code != .cancelled {
                    healthState = .reconnecting(network.localizedDescription)
                }
            }
            throw error
        }
    }

    private func request<T: Decodable>(
        base: URL, path: String, hostID: String? = nil, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        var trace = DiagnosticRequest(method: method, path: path, hostID: hostID, diagnostics: diagnostics)
        request.setValue(trace.actionID, forHTTPHeaderField: "X-SlopZooka-Action-ID")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await exchange(Self.authorized(request, credentials: credentials))
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            trace.completed(response)
            guard (200..<300).contains(response.statusCode) else {
                let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
                throw CompanionError(
                    message: "\(method) \(path) — HTTP \(response.statusCode): \(error?.error ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode))", statusCode: response.statusCode)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            trace.failed(error)
            throw error
        }
    }

    /// Best-effort diagnostics never use the control request wrapper or change
    /// connection state. A failed upload must not generate another upload error.
    func flushDiagnostics() async {
        guard !sendingDiagnostics else { return }
        sendingDiagnostics = true
        defer { sendingDiagnostics = false }
        for (hostID, route) in routes where route.paired && route.health.diagnosticsVersion == 1 {
            let batch = diagnostics.batch(for: hostID)
            guard !batch.isEmpty, let url = URL(string: "/api/diagnostics/events", relativeTo: route.endpoint)?.absoluteURL else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.timeoutInterval = 4
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(hostID, forHTTPHeaderField: "X-SlopZooka-Host-ID")
            request.httpBody = diagnostics.body(for: batch)
            do {
                let (_, response) = try await exchange(Self.authorized(request, credentials: credentials))
                if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) { diagnostics.acknowledge(batch) }
            } catch { /* Retain the bounded outbox until reconnect. */ }
        }
    }

}

/// A request's timing/correlation state; it never owns decoding or connection state.
@MainActor
private struct DiagnosticRequest {
    let actionID = DiagnosticContext.actionID ?? UUID().uuidString
    private let diagnostics: NativeDiagnostics
    private let log: AppLog
    private let method: String
    private let hostID: String?
    private let started = ProcessInfo.processInfo.systemUptime
    private var responseStatus: Int?

    init(method: String, path: String, hostID: String?, diagnostics: NativeDiagnostics) {
        self.method = method
        self.hostID = hostID
        self.diagnostics = diagnostics
        var fields = ["actionId": actionID, "route": String(path.split(separator: "?", maxSplits: 1).first ?? ""), "method": method]
        if let hostID { fields["hostId"] = hostID }
        self.log = AppLog("network", fields: fields, diagnostics: diagnostics)
        if method != "GET" { log.info("http.started") }
    }

    private var durationMs: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

    mutating func completed(_ response: HTTPURLResponse) {
        responseStatus = response.statusCode
        if let hostID {
            diagnostics.calibrate(hostID: hostID, serverTime: response.value(forHTTPHeaderField: "X-SlopZooka-Time"), durationMs: durationMs)
        }
        var fields = ["status": String(response.statusCode), "durationMs": String(durationMs)]
        fields["requestId"] = response.value(forHTTPHeaderField: "X-SlopZooka-Request-ID")
        if response.statusCode >= 400 { log.warn("http.completed", fields) }
        else if method != "GET" { log.info("http.completed", fields) }
    }

    func failed(_ error: Error) {
        guard (responseStatus ?? 0) < 400 else { return } // The HTTP failure was already recorded.
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            log.info("http.cancelled", ["durationMs": String(durationMs)])
            return
        }
        // Server bodies remain with the caller; diagnostics only retain error type/code.
        log.warn("http.failed", ["errorType": String(describing: type(of: error)), "code": String((error as NSError).code), "durationMs": String(durationMs)])
    }
}

struct ConnectedHost: Equatable {
    let id: String
    var revision = UUID()
}

// Foundation delivers these delegate calls on the main run loop used by start().
extension CompanionClient: @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private func key(_ service: NetService) -> String { "\(service.name)|\(service.type)|\(service.domain)" }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services[key(service)] = service
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: key(service))?.stop()
        companions.removeAll { $0.id == key(service) }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        discoveryError = "Bonjour search failed: \(errorDict)"
        slzLog(discoveryError!)
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        guard services[key(service)] === service, service.port > 0,
            let name = service.hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        let hostname = name.hasSuffix(".") ? String(name.dropLast()) : name
        let addresses = (service.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
                    else { return nil }
                let ip = String(cString: buffer)
                return ip.contains(":") ? "[\(ip)]:\(service.port)" : "\(ip):\(service.port)"
            }
        }
        var seen = Set<String>()
        let candidates = (["\(hostname):\(service.port)"] + addresses).filter { seen.insert($0).inserted }
        discoveryError = nil
        companions.removeAll { $0.id == key(service) }
        companions.append(DiscoveredCompanion(id: key(service), name: service.name, candidateHosts: candidates))
        companions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        slzLog("bonjour resolved service name=\(service.name) host=\(candidates[0])")
        Task { [weak self] in await self?.maybeAutoConnect(candidateHosts: candidates) }
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[key(sender)] === sender else { return }
        services.removeValue(forKey: key(sender))
        slzLog("bonjour resolve failed name=\(sender.name): \(errorDict)")
    }
}

/// A host credential is reusable only on routes explicitly paired with that host.
/// An unauthenticated health response never grants a new route access to its token.
@MainActor
struct CompanionCredentials {
    let read: (String) -> String?
    let write: (String, String) throws -> Void

    static let live = CompanionCredentials(read: { key in
        var query = keychainQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }, write: { key, value in
        let query = keychainQuery(key)
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CompanionError(message: "Could not save pairing in Keychain") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CompanionError(message: "Could not save pairing in Keychain")
        }
    })

    func token(for url: URL) -> String? {
        let origin = Self.origin(url)
        if let hostID = read("route:\(origin)") { return read("host:\(hostID)") }
        // Preserve the exact origin spelling used by the old Keychain format.
        let legacy = "\(url.scheme ?? "http")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        return read(legacy) ?? read(origin)
    }
    func migrate(_ url: URL, hostID: String) throws {
        let origin = Self.origin(url)
        if let bound = read("route:\(origin)"), bound != hostID {
            throw CompanionError(message: "This address belongs to a different Mac. Pair it again.")
        }
        guard let token = token(for: url) else { return }
        if read("host:\(hostID)") == nil { try write("host:\(hostID)", token) }
        try write("route:\(origin)", hostID)
    }
    func pair(_ url: URL, hostID: String, token: String) throws {
        try write("host:\(hostID)", token)
        try write("route:\(Self.origin(url))", hostID)
    }
    private static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "http")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
    private static func keychainQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SlopZooka.Companion", kSecAttrAccount as String: key]
    }
}
