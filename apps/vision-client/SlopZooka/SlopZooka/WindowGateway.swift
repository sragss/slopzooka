import Combine
import Foundation

struct TerminalSessionState: Identifiable {
    let payload: TerminalWindowPayload
    var id: String { payload.id }
    let isPresented: Bool
    let isFocused: Bool
    let loadState: TerminalLoadState
    let lastFocusedAt: Date
}

private struct WindowPresence {
    var isPresented = false
    var isFocused = false
    var lastFocusedAt = Date.distantPast
}

enum WindowCommand: Equatable {
    case open(WindowRecord)
    case close(WindowRecord)
    case openLauncher
}

/// The only entry point for window intent, content resolution, and restoration.
/// Views never persist payloads or call native window actions directly.
@MainActor
final class WindowGateway: ObservableObject {
    let immersiveWorkspace = ImmersiveWorkspaceState()
    let launcher = LauncherState()
    let discovery = CompanionDiscovery()
    private let persistence: WindowPersistence
    @Published private var terminals: [String: (payload: TerminalWindowPayload, loadState: TerminalLoadState)] = [:]
    @Published private var presence: [String: WindowPresence] = [:]
    @Published private var previews: [String: PreviewWindowPayload] = [:]
    @Published private var failures: [String: String] = [:]
    @Published private var reloads: [String: Int] = [:]
    @Published private(set) var persistenceError: String?
    @Published private var references: [String: WindowReference] = [:]
    private var refreshPreviews: Set<String> = []
    private var resolvingPreviews: [String: Task<Void, Never>] = [:]
    private var endpoints: [String: URL] = [:]
    private var companionInstances: [String: String] = [:]
    private var requested: Set<String> = []
    private var presenters: [UUID: (WindowCommand) -> Void] = [:]
    private var serviceTask: Task<Void, Never>?
    private var synchronizing = false
    private var renameRequests: [String: UUID] = [:]

    init(persistence: WindowPersistence? = nil) {
        self.persistence = persistence ?? WindowPersistence()
        launcher.launchTerminal = { [weak self] workspaceID, base, profile in
            try await self?.launchTerminal(workspaceID: workspaceID, base: base, profile: profile)
        }
        launcher.onSessionSnapshot = { [weak self] snapshot, target in
            guard let self else { return }
            let hostID = target.id, base = target.endpoint
            self.endpoints[hostID] = base
            if let instance = snapshot.companionInstanceId {
                if let previous = self.companionInstances[hostID], previous != instance {
                    for (id, reference) in self.references where reference.hostID == hostID {
                        if reference.window.kind == .preview {
                            self.refreshPreviews.insert(id)
                            self.resolvingPreviews[id]?.cancel()
                        } else if self.presence[id]?.isPresented == true {
                            // Refresh the authenticated document and its WebSocket,
                            // keeping the native scene and Mac session unchanged.
                            self.reloads[id, default: 0] += 1
                        }
                    }
                }
                self.companionInstances[hostID] = instance
            }
            let sessions = snapshot.sessions
            let ids = Set(sessions.map(\.id))
            for (id, reference) in self.references where reference.hostID == hostID && reference.window.kind == .terminal && !ids.contains(id) {
                self.terminals.removeValue(forKey: id)
                self.failures[id] = "This terminal is no longer available. Its session may have ended or the Mac session service restarted."
            }
            for session in sessions { self.registerTerminal(session, hostID: hostID, base: base) }
            await self.synchronize()
        }
    }

    // App lifetime, not launcher-view lifetime. Any restored scene can start recovery.
    func start() {
        guard serviceTask == nil else { return }
        launcher.loadSavedPreferences()
        discovery.onCompanionResolved = { [weak self] companion in
            guard let self else { return }
            Task { await self.launcher.maybeAutoConnect(candidateHosts: companion.candidateHosts) }
        }
        discovery.start()
        serviceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.launcher.connection.current == nil {
                    await self.launcher.maybeAutoConnect(candidateHosts: [self.launcher.normalizedHost])
                } else { await self.launcher.refreshHostCatalog() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    var terminalSessions: [TerminalSessionState] {
        terminals.map { id, terminal in
            let scene = presence[id, default: WindowPresence()]
            return TerminalSessionState(payload: terminal.payload, isPresented: scene.isPresented,
                isFocused: scene.isFocused, loadState: terminal.loadState, lastFocusedAt: scene.lastFocusedAt)
        }.sorted {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            if $0.isPresented != $1.isPresented { return $0.isPresented }
            if $0.lastFocusedAt != $1.lastFocusedAt { return $0.lastFocusedAt > $1.lastFocusedAt }
            return $0.id < $1.id
        }
    }
    func terminalPayload(for id: String) -> TerminalWindowPayload? { terminals[id]?.payload }

    func rename(id: String, name: String) async throws {
        guard canReceiveVoice(id), let reference = references[id], let base = terminals[id]?.payload.url else {
            throw CompanionError(message: "Reconnect to this terminal before renaming it.")
        }
        let normalized = WindowName.normalized(name)
        guard !normalized.isEmpty, normalized.utf16.count <= 120,
            !normalized.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw CompanionError(message: "Speak a window name of 120 characters or fewer.")
        }
        let token = UUID()
        renameRequests[id] = token
        defer { if renameRequests[id] == token { renameRequests.removeValue(forKey: id) } }
        let result = try await CompanionAPI.request(CreatedSessionResponse.self, base: base,
            path: "/api/sessions/\(id)", method: "PATCH",
            body: JSONSerialization.data(withJSONObject: ["name": normalized]))
        guard renameRequests[id] == token, references[id]?.hostID == reference.hostID else { return }
        registerTerminal(result.session, hostID: reference.hostID, base: base)
    }
    func previewPayload(for id: String) -> PreviewWindowPayload? { previews[id] }
    func reference(for id: String) -> WindowReference? { references[id] }
    func remember(_ reference: WindowReference) {
        if references[reference.window.id] == nil { references[reference.window.id] = reference }
    }
    func message(for id: String) -> String { failures[id] ?? persistenceError ?? "Reconnecting to your Mac…" }
    func contentError(for id: String) -> String? { failures[id] }
    func reloadToken(for id: String) -> Int { reloads[id, default: 0] }
    func updateTerminalLoadState(id: String, loadState: TerminalLoadState) { terminals[id]?.loadState = loadState }

    func canReceiveVoice(_ id: String) -> Bool {
        guard let scene = presence[id], scene.isPresented, scene.isFocused,
            let reference = references[id], persistence.windows(hostID: reference.hostID).contains(reference.window),
            case .loaded = terminals[id]?.loadState else { return false }
        return true
    }

    func submitVoiceInput(_ command: TerminalVoiceCommand) async throws {
        guard canReceiveVoice(command.targetID), let base = terminalPayload(for: command.targetID)?.url else {
            throw CompanionError(message: "Terminal is not connected. Reconnect, then retry.")
        }
        let path = "/api/sessions/\(command.targetID)/input"
        let body = try JSONSerialization.data(withJSONObject: [
            "commandId": command.commandID, "text": command.text, "sendReturn": true,
        ])
        for attempt in 0..<2 {
            do {
                _ = try await CompanionAPI.request(APIAcknowledgement.self, base: base, path: path, method: "POST", body: body)
                return
            } catch let error as URLError
                where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                try await Task.sleep(for: .milliseconds(300))
                guard canReceiveVoice(command.targetID) else { throw error }
            }
        }
    }

    func open(id: String) throws {
        guard let reference = references[id] else { throw CompanionError(message: "Reconnect to your Mac before opening this window.") }
        try persistence.set(reference, isOpen: true)
        failures.removeValue(forKey: id)
        present(reference.window, explicit: true)
        Task { await synchronize() }
    }
    func openPreview(_ frontend: FrontendSummary, base: URL) throws {
        let hostID = try hostID(for: base)
        let id = "\(hostID):\(frontend.id)"
        references[id] = WindowReference(hostID: hostID, window: WindowRecord(id: id, kind: .preview, targetID: frontend.id))
        try open(id: id)
    }
    func close(id: String) {
        guard let reference = references[id] else { return }
        close(reference)
    }
    func close(_ reference: WindowReference, dismiss: Bool = true) {
        do {
            try persistence.set(reference, isOpen: false)
            requested.remove(reference.window.id)
            resolvingPreviews[reference.window.id]?.cancel()
            previews.removeValue(forKey: reference.window.id)
            failures.removeValue(forKey: reference.window.id)
            if dismiss { presenters.values.first?(.close(reference.window)) }
            Task { await synchronize() }
        } catch { persistenceError = "Could not save the window layout: \(error.localizedDescription)" }
    }
    func openLauncher() { presenters.values.first?(.openLauncher) }

    func newShell(for id: String) async throws {
        guard let payload = terminalPayload(for: id), let base = payload.url else { return }
        try await launchTerminal(workspaceID: payload.workspaceId, base: base, profile: nil)
    }
    private func launchTerminal(workspaceID: String, base: URL, profile: String?) async throws {
        let hostID = try hostID(for: base)
        let result = try await CompanionAPI.request(CreatedSessionResponse.self, base: base,
            path: "/api/workspaces/\(workspaceID)/sessions", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["sessionId": UUID().uuidString, "profile": profile as Any? ?? NSNull()]))
        try Task.checkCancellation()
        registerTerminal(result.session, hostID: hostID, base: base)
        try open(id: result.session.id)
    }
    func endSession(id: String) async throws {
        guard let base = terminalPayload(for: id)?.url else { return }
        _ = try await CompanionAPI.request(APIAcknowledgement.self, base: base, path: "/api/sessions/\(id)", method: "DELETE")
        close(id: id)
    }

    /// Reload content while preserving native scenes, placement, and running PTYs.
    func reload(id: String? = nil) {
        for windowID in id.map({ [$0] }) ?? presence.compactMap({ $0.value.isPresented ? $0.key : nil }) {
            reloads[windowID, default: 0] += 1
            if references[windowID]?.window.kind == .preview { refreshPreviews.insert(windowID) }
            failures.removeValue(forKey: windowID)
        }
        Task { await synchronize() }
    }

    // Called only by WindowScene. Presence is ephemeral and never writes close intent.
    func observe(id: String?, isPresented: Bool, isFocused: Bool) {
        guard let id else { return }
        requested.insert(id) // An existing background scene is also already restored.
        presence[id] = WindowPresence(isPresented: isPresented, isFocused: isFocused,
            lastFocusedAt: isFocused ? Date() : presence[id]?.lastFocusedAt ?? .distantPast)
    }
    func attachPresenter(_ id: UUID, action: @escaping (WindowCommand) -> Void) {
        presenters[id] = action
        restoreWindows()
    }
    func detachPresenter(_ id: UUID) { presenters.removeValue(forKey: id) }

    private func hostID(for base: URL) throws -> String {
        func origin(_ url: URL) -> String { "\(url.scheme ?? "http")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))" }
        if let target = launcher.connection.current, origin(target.endpoint) == origin(base) {
            endpoints[target.id] = target.endpoint
            return target.id
        }
        guard let hostID = endpoints.first(where: { origin($0.value) == origin(base) })?.key else {
            throw CompanionError(message: "Connect to this Mac before opening a window.")
        }
        return hostID
    }
    private func registerTerminal(_ session: HostSession, hostID: String, base: URL) {
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.path = "/terminal"
        url.queryItems = [URLQueryItem(name: "sessionId", value: session.id)]
        let payload = TerminalWindowPayload(id: session.id, workspaceId: session.workspaceId,
            title: session.name ?? "\(session.title) • \(URL(fileURLWithPath: session.cwd).lastPathComponent)",
            urlString: url.url!.absoluteString)
        terminals[session.id] = (payload, terminals[session.id]?.loadState ?? .idle)
        references[session.id] = WindowReference(hostID: hostID,
            window: WindowRecord(id: session.id, kind: .terminal, targetID: session.id))
        failures.removeValue(forKey: session.id)
    }
    private func synchronize() async {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        var errors: [String] = []
        for (hostID, base) in endpoints {
            do {
                try await persistence.synchronize(hostID: hostID, base: base)
            } catch { errors.append("Window recovery needs attention: \(error.localizedDescription)") }
            restoreWindows()
            for record in persistence.windows(hostID: hostID) where record.kind == .preview && (previews[record.id] == nil || refreshPreviews.contains(record.id)) {
                resolve(record, hostID: hostID, base: base)
            }
        }
        persistenceError = errors.first
    }
    private func resolve(_ record: WindowRecord, hostID: String, base: URL) {
        guard resolvingPreviews[record.id] == nil else { return }
        refreshPreviews.remove(record.id)
        // Content availability never blocks intent persistence or other windows.
        resolvingPreviews[record.id] = Task {
            defer { resolvingPreviews.removeValue(forKey: record.id) }
            do {
                let payload = try await resolvePreview(record, base: base)
                guard !Task.isCancelled, persistence.windows(hostID: hostID).contains(record) else { return }
                previews[record.id] = payload
                failures.removeValue(forKey: record.id)
            } catch {
                if !Task.isCancelled { failures[record.id] = error.localizedDescription }
            }
        }
    }
    private func restoreWindows() {
        for hostID in endpoints.keys {
            for record in persistence.windows(hostID: hostID) {
                references[record.id] = WindowReference(hostID: hostID, window: record)
                if record.kind == .terminal && terminals[record.id] == nil {
                    failures[record.id] = "This terminal is no longer available. Its session may have ended or the Mac session service restarted."
                }
                present(record)
            }
        }
    }
    private func present(_ record: WindowRecord, explicit: Bool = false) {
        guard (explicit || !requested.contains(record.id)), let action = presenters.values.first else { return }
        requested.insert(record.id)
        action(.open(record))
    }
    private func resolvePreview(_ record: WindowRecord, base: URL) async throws -> PreviewWindowPayload {
        let result = try await CompanionAPI.request(OpenFrontendResponse.self, base: base,
            path: "/api/frontends/open", method: "POST", body: JSONSerialization.data(withJSONObject: ["id": record.targetID]))
        guard var url = URLComponents(string: result.frontend.url) else { throw URLError(.badURL) }
        if let port = result.exposedPort, let token = result.accessToken {
            url.scheme = result.gatewayScheme ?? "http"
            if result.frontend.url.hasPrefix("https://") && url.scheme != "https" {
                throw CompanionError(message: "Update the Mac companion to open this HTTPS app securely.")
            }
            url.host = base.host
            url.port = port
            url.path = "/__slz_access"
            url.fragment = nil
            url.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let resolved = url.url else { throw URLError(.badURL) }
        return PreviewWindowPayload(id: record.id, title: result.frontend.displayTitle,
            urlString: resolved.absoluteString, certificateAuthority: result.certificateAuthority)
    }
}
