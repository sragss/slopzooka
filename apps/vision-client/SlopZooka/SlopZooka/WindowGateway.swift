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

private struct WindowState {
    enum Content {
        case terminal(TerminalWindowPayload)
        case preview(PreviewWindowPayload, revision: Int)
    }
    var reference: WindowReference?
    var content: Content?
    var isPresented = false
    var isFocused = false
    var lastFocusedAt = Date.distantPast
    var loadState: TerminalLoadState = .idle
    var notifications = TerminalNotifications()
    var error: String?
    var reloadRevision = 0
    var openRequested = false
    var renameRequest: UUID?
    var previewRequest: (revision: Int, task: Task<Void, Never>)?

    var terminal: TerminalWindowPayload? { if case .terminal(let payload) = content { return payload }; return nil }
    var preview: PreviewWindowPayload? { if case .preview(let payload, _) = content { return payload }; return nil }
    var resolvedPreviewRevision: Int? { if case .preview(_, let revision) = content { return revision }; return nil }

    mutating func invalidateContent() {
        reloadRevision += 1
        previewRequest?.task.cancel()
        previewRequest = nil
        error = nil
    }

    mutating func markTerminalUnavailable() {
        content = nil
        loadState = .idle
        notifications = TerminalNotifications()
        renameRequest = nil
        error = "This terminal is no longer available. Its session may have ended or the Mac session service restarted."
    }
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
    private let log = AppLog("windows")
    let immersiveWorkspace = ImmersiveWorkspaceState()
    let launcher: LauncherState
    let client: CompanionClient
    private let persistence: WindowPersistence
    @Published private var windows: [String: WindowState] = [:]
    @Published private(set) var persistenceError: String?
    private var companionInstances: [String: (route: UUID, process: String?)] = [:]
    private var presenters: [UUID: (WindowCommand) -> Void] = [:]
    private var isSynchronizing = false

    init(persistence: WindowPersistence? = nil, client: CompanionClient? = nil) {
        self.client = client ?? CompanionClient()
        self.launcher = LauncherState(client: self.client)
        self.persistence = persistence ?? WindowPersistence()
        launcher.launchTerminal = { [weak self] workspaceID, hostID, profile in
            try await self?.launchTerminal(workspaceID: workspaceID, hostID: hostID, profile: profile)
        }
        self.client.onSessionSnapshot = { [weak self] snapshot, target in
            guard let self else { return }
            let hostID = target.id
            let instance = (route: target.revision, process: snapshot.companionInstanceId)
            if let previous = self.companionInstances[hostID], previous != instance {
                for (id, window) in self.windows where window.reference?.hostID == hostID {
                    if window.reference?.window.kind == .preview || window.isPresented {
                        // Refresh the authenticated document and its WebSocket,
                        // keeping the native scene and Mac session unchanged.
                        self.windows[id]?.invalidateContent()
                    }
                }
            }
            self.companionInstances[hostID] = instance
            let sessions = snapshot.sessions
            let ids = Set(sessions.map(\.id))
            for (id, window) in self.windows where window.reference?.hostID == hostID && window.reference?.window.kind == .terminal && !ids.contains(id) {
                self.windows[id]?.markTerminalUnavailable()
            }
            for session in sessions { self.registerTerminal(session, hostID: hostID) }
            await self.synchronize()
        }
    }

    func start() { client.start() }

    var terminalSessions: [TerminalSessionState] {
        windows.values.compactMap { window -> TerminalSessionState? in
            guard let payload = window.terminal else { return nil }
            return TerminalSessionState(payload: payload, isPresented: window.isPresented,
                isFocused: window.isFocused, loadState: window.loadState, lastFocusedAt: window.lastFocusedAt)
        }.sorted {
            if $0.isFocused != $1.isFocused { return $0.isFocused }
            if $0.isPresented != $1.isPresented { return $0.isPresented }
            if $0.lastFocusedAt != $1.lastFocusedAt { return $0.lastFocusedAt > $1.lastFocusedAt }
            return $0.id < $1.id
        }
    }
    func terminalPayload(for id: String) -> TerminalWindowPayload? { windows[id]?.terminal }

    func rename(id: String, name: String, target: TerminalVoiceController.NameTarget = .window) async throws {
        log.info("rename.requested", ["windowId": id, "hostId": windows[id]?.reference?.hostID ?? "", "target": target.rawValue])
        guard canRename(id), let reference = windows[id]?.reference else {
            throw CompanionError(message: "Reconnect to this terminal before renaming it.")
        }
        let normalized = WindowName.normalized(name)
        guard !normalized.isEmpty, normalized.utf16.count <= 120,
            !normalized.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw CompanionError(message: "Speak a name of 120 characters or fewer.")
        }
        let token = UUID()
        windows[id]?.renameRequest = token
        defer { if windows[id]?.renameRequest == token { windows[id]?.renameRequest = nil } }
        if target == .workspace, let workspaceID = windows[id]?.terminal?.workspaceId {
            try await client.renameWorkspace(hostID: reference.hostID, id: workspaceID, name: normalized)
            await client.refreshSessions(hostID: reference.hostID, force: true)
            await launcher.loadWorkspaces(hostID: reference.hostID)
        } else {
            let result = try await client.renameSession(hostID: reference.hostID, id: id, name: normalized)
            guard windows[id]?.renameRequest == token, windows[id]?.reference?.hostID == reference.hostID else { return }
            registerTerminal(result.session, hostID: reference.hostID)
            await client.refreshSessions(hostID: reference.hostID, force: true)
        }
    }
    func previewPayload(for id: String) -> PreviewWindowPayload? { windows[id]?.preview }
    func reference(for id: String) -> WindowReference? { windows[id]?.reference }
    func remember(_ reference: WindowReference) {
        if windows[reference.window.id]?.reference == nil { windows[reference.window.id, default: WindowState()].reference = reference }
    }
    func message(for id: String) -> String { windows[id]?.error ?? persistenceError ?? "Reconnecting to your Mac…" }
    func contentError(for id: String) -> String? { windows[id]?.error }
    func reloadToken(for id: String) -> Int { windows[id]?.reloadRevision ?? 0 }
    func updateTerminalLoadState(id: String, loadState: TerminalLoadState) {
        if windows[id]?.terminal != nil { windows[id]?.loadState = loadState }
    }

    func hasUnreadNotification(_ id: String) -> Bool { windows[id]?.notifications.hasUnread == true }
    @discardableResult
    func receiveTerminalNotification(id: String, sequence: Int, serviceInstanceID: String) -> Bool {
        guard let window = windows[id], window.terminal != nil else { return false }
        var next = window.notifications
        let isNew = next.receive(sequence: sequence, serviceInstanceID: serviceInstanceID)
        if window.notifications != next { windows[id]?.notifications = next }
        return isNew
    }
    func readTerminalNotifications(id: String) {
        guard hasUnreadNotification(id) else { return }
        windows[id]?.notifications.markRead()
    }

    func canRename(_ id: String) -> Bool {
        windows[id]?.terminal != nil && windows[id]?.reference != nil
    }

    func canReceiveVoice(_ id: String) -> Bool {
        guard let window = windows[id], window.isPresented, window.isFocused,
            let reference = window.reference, persistence.windows(hostID: reference.hostID).contains(reference.window),
            window.terminal != nil, case .loaded = window.loadState else { return false }
        return true
    }

    func submitVoiceInput(_ command: TerminalVoiceCommand) async throws {
        guard canReceiveVoice(command.targetID), let reference = windows[command.targetID]?.reference else {
            throw CompanionError(message: "Terminal is not connected. Reconnect, then retry.")
        }
        for attempt in 0..<2 {
            do {
                try await client.submitInput(hostID: reference.hostID, sessionID: command.targetID, commandID: command.commandID, text: command.text)
                return
            } catch let error as URLError
                where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                try await Task.sleep(for: .milliseconds(300))
                guard canReceiveVoice(command.targetID) else { throw error }
            }
        }
    }

    func open(id: String) throws {
        guard let reference = windows[id]?.reference else { throw CompanionError(message: "Reconnect to your Mac before opening this window.") }
        log.info("window.open.requested", ["windowId": id, "hostId": reference.hostID, "kind": reference.window.kind.rawValue])
        try persistence.set(reference, isOpen: true)
        windows[id]?.error = nil
        present(reference.window, explicit: true)
        Task { await synchronize() }
    }
    func openPreview(_ frontend: FrontendSummary, hostID: String) throws {
        let id = "\(hostID):\(frontend.id)"
        remember(WindowReference(hostID: hostID, window: WindowRecord(id: id, kind: .preview, targetID: frontend.id)))
        try open(id: id)
    }
    func close(id: String) {
        guard let reference = windows[id]?.reference else { return }
        close(reference)
    }
    func close(_ reference: WindowReference, dismiss: Bool = true) {
        log.info("window.close.requested", ["windowId": reference.window.id, "hostId": reference.hostID, "dismiss": String(dismiss)])
        do {
            try persistence.set(reference, isOpen: false)
            remember(reference)
            let id = reference.window.id
            windows[id]?.invalidateContent()
            windows[id]?.openRequested = false
            if reference.window.kind == .preview { windows[id]?.content = nil }
            if dismiss { presenters.values.first?(.close(reference.window)) }
            Task { await synchronize() }
        } catch { persistenceError = "Could not save the window layout: \(error.localizedDescription)" }
    }
    func openLauncher() { presenters.values.first?(.openLauncher) }

    func newShell(for id: String) async throws {
        guard let payload = terminalPayload(for: id), let reference = windows[id]?.reference else { return }
        try await launchTerminal(workspaceID: payload.workspaceId, hostID: reference.hostID, profile: nil)
    }
    private func launchTerminal(workspaceID: String, hostID: String, profile: String?) async throws {
        try await log.operation("session.launch", ["workspaceId": workspaceID, "hostId": hostID]) {
            let result = try await client.launchSession(hostID: hostID, workspaceID: workspaceID, sessionID: UUID().uuidString, profile: profile)
            try Task.checkCancellation()
            registerTerminal(result.session, hostID: hostID)
            try open(id: result.session.id)
        }
    }
    func endSession(id: String) async throws {
        guard let reference = windows[id]?.reference else { return }
        try await client.endSession(hostID: reference.hostID, id: id)
        close(id: id)
    }

    /// Reload content while preserving native scenes, placement, and running PTYs.
    func reload(id: String? = nil) {
        log.info("content.reload.requested", ["windowId": id ?? "all", "hostId": id.flatMap { windows[$0]?.reference?.hostID } ?? client.current?.id ?? ""])
        for windowID in id.map({ [$0] }) ?? windows.compactMap({ $0.value.isPresented ? $0.key : nil }) {
            windows[windowID]?.invalidateContent()
        }
        Task { await synchronize() }
    }

    // Called only by WindowScene. Presence is ephemeral and never writes close intent.
    func observe(id: String?, isPresented: Bool, isFocused: Bool) {
        guard let id else { return }
        if windows[id]?.isPresented != isPresented || windows[id]?.isFocused != isFocused {
            log.info("scene.observed", ["windowId": id, "hostId": windows[id]?.reference?.hostID ?? "", "presented": String(isPresented), "focused": String(isFocused)])
        }
        windows[id, default: WindowState()].openRequested = true // A background scene is also already restored.
        windows[id]?.isPresented = isPresented
        windows[id]?.isFocused = isFocused
        if isFocused { windows[id]?.lastFocusedAt = Date() }
    }
    func attachPresenter(_ id: UUID, action: @escaping (WindowCommand) -> Void) {
        presenters[id] = action
        restoreWindows()
    }
    func detachPresenter(_ id: UUID) { presenters.removeValue(forKey: id) }

    private func registerTerminal(_ session: HostSession, hostID: String) {
        guard let base = try? client.endpoint(for: hostID) else { return }
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.path = "/terminal"
        url.queryItems = [URLQueryItem(name: "sessionId", value: session.id)]
        let payload = TerminalWindowPayload(id: session.id, workspaceId: session.workspaceId,
            title: session.name ?? (session.workspaceName == nil ? "\(session.title) • \(URL(fileURLWithPath: session.cwd).lastPathComponent)" : session.title),
            urlString: url.url!.absoluteString, projectName: session.projectName, workspaceName: session.workspaceName)
        windows[session.id, default: WindowState()].content = .terminal(payload)
        windows[session.id]?.reference = WindowReference(hostID: hostID,
            window: WindowRecord(id: session.id, kind: .terminal, targetID: session.id))
        windows[session.id]?.error = nil
    }
    private func synchronize() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        var firstError: String?
        for hostID in client.knownHostIDs {
            do {
                try await persistence.synchronize(hostID: hostID, client: client)
            } catch {
                log.error("recovery.failed", error: error, ["hostId": hostID])
                firstError = firstError ?? "Window recovery needs attention: \(error.localizedDescription)"
            }
            restoreWindows(hostID: hostID)
            for record in persistence.windows(hostID: hostID) where record.kind == .preview {
                resolve(record, hostID: hostID)
            }
        }
        persistenceError = firstError
    }
    private func resolve(_ record: WindowRecord, hostID: String) {
        let revision = reloadToken(for: record.id)
        guard windows[record.id]?.resolvedPreviewRevision != revision,
            windows[record.id]?.previewRequest?.revision != revision else { return }
        windows[record.id]?.previewRequest?.task.cancel()
        // Content availability never blocks intent persistence or other windows.
        let task = Task {
            defer { if windows[record.id]?.previewRequest?.revision == revision { windows[record.id]?.previewRequest = nil } }
            do {
                let payload = try await resolvePreview(record, hostID: hostID)
                guard !Task.isCancelled, reloadToken(for: record.id) == revision,
                    persistence.windows(hostID: hostID).contains(record) else { return }
                windows[record.id]?.content = .preview(payload, revision: revision)
                windows[record.id]?.error = nil
            } catch {
                guard !Task.isCancelled, reloadToken(for: record.id) == revision else { return }
                log.error("preview.resolve.failed", error: error, ["hostId": hostID, "windowId": record.id, "revision": String(revision)])
                windows[record.id]?.error = error.localizedDescription
            }
        }
        windows[record.id]?.previewRequest = (revision, task)
    }
    private func restoreWindows(hostID: String? = nil) {
        for hostID in hostID.map({ [$0] }) ?? Array(client.knownHostIDs) {
            for record in persistence.windows(hostID: hostID) {
                windows[record.id, default: WindowState()].reference = WindowReference(hostID: hostID, window: record)
                if record.kind == .terminal && windows[record.id]?.terminal == nil {
                    windows[record.id]?.markTerminalUnavailable()
                }
                present(record)
            }
        }
    }
    private func present(_ record: WindowRecord, explicit: Bool = false) {
        guard (explicit || windows[record.id]?.openRequested != true), let action = presenters.values.first else { return }
        windows[record.id, default: WindowState()].openRequested = true
        action(.open(record))
    }
    private func resolvePreview(_ record: WindowRecord, hostID: String) async throws -> PreviewWindowPayload {
        let result = try await client.openFrontend(hostID: hostID, id: record.targetID)
        guard var url = URLComponents(string: result.frontend.url) else { throw URLError(.badURL) }
        if let port = result.exposedPort, let token = result.accessToken {
            url.scheme = result.gatewayScheme ?? "http"
            if result.frontend.url.hasPrefix("https://") && url.scheme != "https" {
                throw CompanionError(message: "Update the Mac companion to open this HTTPS app securely.")
            }
            url.host = try client.endpoint(for: hostID).host
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
