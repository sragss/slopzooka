import Foundation

// No discovery or process launch in these checks. Production gateway/persistence/
// launcher code runs against a controllable transport, including delayed replies.
@MainActor
final class CompanionDiscovery {
    var onCompanionResolved: ((DiscoveredCompanion) -> Void)?
    func start() {}
}

@MainActor
enum CompanionAPI {
    static var layouts: [String: WindowLayout] = [:]
    static var beforePut: (() async -> Void)?
    static var beforePreview: (() async -> Void)?
    static var beforeSessions: (() async throws -> Void)?
    static var sessions: [String: [HostSession]] = [:]
    static var sessionEndpoints: [URL] = []
    static var replyVersion = 1
    static var putReplyVersion = 1
    static var loseReply = false
    static var previewPort = 12345
    static var requests: [String] = []
    static func baseURL(host: String) -> URL? { URL(string: host.contains("://") ? host : "http://\(host)") }
    static func pair(base: URL, code: String) async throws {}
    static func request<T: Decodable>(_ type: T.Type, base: URL, path: String,
        method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) async throws -> T {
        requests.append("\(method) \(path)")
        if path == "/api/window-layout" {
            let key = base.host!
            if method == "PUT" {
                var next = try JSONDecoder().decode(WindowLayout.self, from: body!)
                if let callback = beforePut { beforePut = nil; await callback() }
                guard next.revision == layouts[key, default: WindowLayout()].revision else {
                    throw CompanionError(message: "Conflict", statusCode: 409)
                }
                next.revision += 1
                layouts[key] = next
                if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
            }
            var reply = layouts[key, default: WindowLayout()]
            reply.version = method == "PUT" ? putReplyVersion : replyVersion
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(reply))
        }
        if path == "/api/sessions" {
            sessionEndpoints.append(base)
            if let callback = beforeSessions { beforeSessions = nil; try await callback() }
            return HostSessionsResponse(sessions: sessions[base.host!] ?? []) as! T
        }
        if path == "/api/frontends" { return FrontendCatalog(frontends: [], warning: nil) as! T }
        if path == "/api/frontends/open" {
            if let callback = beforePreview { beforePreview = nil; await callback() }
            return try JSONDecoder().decode(T.self, from: Data("""
                {"frontend":{"id":"web","hostname":"localhost","url":"https://localhost/app","transport":"gateway"},
                 "exposedPort":\(previewPort),"accessToken":"transient-secret","gatewayScheme":"https","certificateAuthority":"public-ca"}
                """.utf8))
        }
        throw CompanionError(message: "Unexpected request: \(method) \(path)")
    }
}

@main
struct WindowGatewayChecks {
    @MainActor
    static func main() async throws {
        let suite = "WindowGatewayChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = URL(string: "http://fixture.invalid:7777")!
        let hostID = "host-1"
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let contract = try JSONDecoder().decode(WindowLayout.self, from: data).validated()
        let encodedContract = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contract)) as! NSDictionary
        let expectedContract = try JSONSerialization.jsonObject(with: data)
        precondition(encodedContract.isEqual(expectedContract))
        let terminal = contract.windows[0], preview = contract.windows[1]
        precondition(terminal.kind == .terminal && preview.kind == .preview)
        let target = ConnectedHost(id: hostID, endpoint: base)
        let reference = WindowReference(hostID: hostID, window: terminal)
        let store = WindowPersistence(defaults: defaults)
        try store.set(reference, isOpen: true)
        // Process replacement before upload still has its unacknowledged open.
        let restored = WindowPersistence(defaults: defaults)
        precondition(restored.windows(hostID: hostID) == [terminal])
        try await restored.synchronize(hostID: hostID, base: base)
        let fromMac = WindowPersistence(defaults: defaults)
        try await fromMac.synchronize(hostID: hostID, base: base)
        precondition(fromMac.windows(hostID: hostID) == [terminal])
        precondition(fromMac.windows(hostID: "another-mac").isEmpty)

        CompanionAPI.replyVersion = 2
        do { try await fromMac.synchronize(hostID: hostID, base: base); preconditionFailure("Expected unsupported version") }
        catch {}
        CompanionAPI.replyVersion = 1
        try fromMac.set(reference, isOpen: true)
        CompanionAPI.putReplyVersion = 2
        do { try await fromMac.synchronize(hostID: hostID, base: base); preconditionFailure("Expected unsupported acknowledgement") }
        catch {}
        precondition(WindowPersistence(defaults: defaults).windows(hostID: hostID) == [terminal], "An unsupported acknowledgement cannot clear pending intent")
        CompanionAPI.putReplyVersion = 1
        try await fromMac.synchronize(hostID: hostID, base: base)

        var release: CheckedContinuation<Void, Never>?
        CompanionAPI.beforePut = { await withCheckedContinuation { release = $0 } }
        try fromMac.set(reference, isOpen: true)
        let upload = Task { try await fromMac.synchronize(hostID: hostID, base: base) }
        await until { release != nil }
        try fromMac.set(reference, isOpen: false)
        release!.resume()
        try await upload.value
        precondition(fromMac.windows(hostID: hostID).isEmpty, "A late open acknowledgement cannot erase a newer close")
        CompanionAPI.loseReply = true
        do { try await fromMac.synchronize(hostID: hostID, base: base); preconditionFailure("Expected dropped reply") }
        catch {}
        let afterLostReply = WindowPersistence(defaults: defaults)
        precondition(afterLostReply.windows(hostID: hostID).isEmpty)
        try await afterLostReply.synchronize(hostID: hostID, base: base)
        precondition(CompanionAPI.layouts[base.host!]!.windows.isEmpty)

        try afterLostReply.set(reference, isOpen: true)
        CompanionAPI.beforePut = {
            var concurrent = CompanionAPI.layouts[base.host!]!
            concurrent.windows = [preview]
            concurrent.revision += 1
            CompanionAPI.layouts[base.host!] = concurrent
        }
        do { try await afterLostReply.synchronize(hostID: hostID, base: base); preconditionFailure("Expected revision conflict") }
        catch {}
        try await afterLostReply.synchronize(hostID: hostID, base: base)
        precondition(Set(afterLostReply.windows(hostID: hostID)) == Set([terminal, preview]), "Retry rebases only local intent, preserving other saved windows")
        print("PASS: restart, in-flight close, lost replies, host isolation, and revision conflicts preserve intent")

        let gateway = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        var opened: [String] = []
        var dismissed: [String] = []
        let presenterID = UUID()
        gateway.observe(id: terminal.id, isPresented: true, isFocused: true)
        var commands: [WindowCommand] = []
        gateway.attachPresenter(presenterID) { command in
            commands.append(command)
            switch command {
            case .open(let window): opened.append(window.id)
            case .close(let window): dismissed.append(window.id)
            case .openLauncher: break
            }
        }
        let session = HostSession(id: terminal.id, workspaceId: "workspace", profile: nil,
            title: "Shell", cwd: "/project", status: "running")
        let closedSession = HostSession(id: "closed-session", workspaceId: "workspace", profile: nil,
            title: "Detached", cwd: "/project", status: "running")
        await gateway.launcher.onSessionSnapshot?([session, closedSession], target)
        await until { gateway.previewPayload(for: preview.id) != nil }
        precondition(opened == [preview.id], "An OS-restored scene is reused; only missing windows are opened")
        precondition(gateway.terminalPayload(for: terminal.id) != nil)
        precondition(gateway.terminalSessions.first?.id == terminal.id)
        precondition(gateway.terminalSessions.first?.isFocused == true, "Presence observed before payload resolution is retained")
        let lastFocused = gateway.terminalSessions.first!.lastFocusedAt
        gateway.openLauncher()
        precondition(commands.last == .openLauncher)
        precondition(gateway.previewPayload(for: preview.id)?.url?.scheme == "https")
        CompanionAPI.previewPort = 12346
        gateway.reload(id: preview.id)
        precondition(gateway.reloadToken(for: preview.id) == 1, "Existing content reloads without waiting for the companion")
        await until { gateway.previewPayload(for: preview.id)?.url?.port == 12346 }
        gateway.reload(id: terminal.id)
        precondition(gateway.reloadToken(for: terminal.id) == 1)
        precondition(opened == [preview.id], "Content reload must not reopen scenes or open detached sessions")
        gateway.observe(id: terminal.id, isPresented: false, isFocused: false)
        gateway.detachPresenter(presenterID)
        await gateway.launcher.onSessionSnapshot?([session], target)
        precondition(CompanionAPI.layouts[base.host!]!.windows.count == 2, "Background and disconnect never close saved windows")
        precondition(opened.count == 1)
        precondition(gateway.terminalSessions.first?.isPresented == false)
        precondition(gateway.terminalSessions.first?.isFocused == false)
        precondition(gateway.terminalSessions.first?.lastFocusedAt == lastFocused, "Catalog refresh does not reset scene activity")
        gateway.close(WindowReference(hostID: hostID, window: preview), dismiss: false)
        await until { CompanionAPI.layouts[base.host!]!.windows.count == 1 }
        precondition(dismissed.isEmpty, "System discard must not recursively request another dismissal")

        // Restored scenes may be discarded before connection/bootstrap completes.
        let next = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        next.close(reference, dismiss: false)
        next.attachPresenter(UUID()) { if case .open(let window) = $0 { opened.append(window.id) } }
        await next.launcher.onSessionSnapshot?([session], target)
        await until { CompanionAPI.layouts[base.host!]!.windows.isEmpty }
        precondition(opened == [preview.id], "A cold-start discard must win over the remote snapshot")
        precondition(!CompanionAPI.requests.contains(where: { $0.contains("/sessions") }), "Recovery never spawns replacement processes")
        print("PASS: independent scene recovery, deduplicated presentation, and explicit closure")

        CompanionAPI.layouts[base.host!] = WindowLayout(windows: [terminal])
        let missing = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        var missingOpens = 0
        missing.attachPresenter(UUID()) { if case .open = $0 { missingOpens += 1 } }
        await missing.launcher.onSessionSnapshot?([], target)
        await missing.launcher.onSessionSnapshot?([], target)
        precondition(missingOpens == 1 && missing.terminalPayload(for: terminal.id) == nil)
        precondition(missing.message(for: terminal.id).contains("no longer available"))
        let background = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        background.observe(id: terminal.id, isPresented: false, isFocused: false)
        background.attachPresenter(UUID()) { if case .open = $0 { missingOpens += 1 } }
        await background.launcher.onSessionSnapshot?([session], target)
        precondition(missingOpens == 1, "A restored background scene must not be pulled forward")
        print("PASS: missing sessions stay unavailable and restored background scenes stay in place")

        // Closing a preview while its gateway is being resolved cannot resurrect it.
        CompanionAPI.layouts[base.host!] = WindowLayout(windows: [preview])
        var releasePreview: CheckedContinuation<Void, Never>?
        var finishedPreview = false
        CompanionAPI.beforePreview = {
            await withCheckedContinuation { releasePreview = $0 }
            finishedPreview = true
        }
        let latePreview = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        let refresh = Task { await latePreview.launcher.onSessionSnapshot?([], target) }
        await until { releasePreview != nil }
        latePreview.close(WindowReference(hostID: hostID, window: preview), dismiss: false)
        await until { CompanionAPI.layouts[base.host!]!.windows.isEmpty }
        releasePreview!.resume()
        await refresh.value
        await until { finishedPreview }
        precondition(latePreview.previewPayload(for: preview.id) == nil)
        await latePreview.launcher.onSessionSnapshot?([], target)
        precondition(CompanionAPI.layouts[base.host!]!.windows.isEmpty)
        let encoded = try JSONEncoder().encode(CompanionAPI.layouts[base.host!]!)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("transient-secret"))
        print("PASS: late preview resolution cannot resurrect a closed window")

        gateway.attachPresenter(presenterID) { commands.append($0) }
        gateway.close(reference)
        precondition(commands.last == .close(terminal))
        await gateway.launcher.onSessionSnapshot?([session], target)
        print("PASS: shared layout contract and typed scene commands preserve identity")

        // Poll the accepted connection while the next address is being edited.
        let otherBase = URL(string: "http://other.invalid:7777")!
        let otherWindow = WindowRecord(id: "terminal-2", kind: .terminal, targetID: "terminal-2")
        let otherSession = HostSession(id: otherWindow.id, workspaceId: "workspace", profile: nil,
            title: "Other shell", cwd: "/other", status: "running")
        CompanionAPI.layouts[base.host!] = WindowLayout(windows: [terminal])
        CompanionAPI.layouts[otherBase.host!] = WindowLayout(windows: [otherWindow])
        CompanionAPI.sessions = [base.host!: [session], otherBase.host!: [otherSession]]
        let switchingStore = WindowPersistence(defaults: defaults)
        let switching = WindowGateway(persistence: switchingStore)
        try accept(target, in: switching.launcher.connection)
        switching.launcher.host = otherBase.absoluteString
        await switching.launcher.refreshHostCatalog()
        precondition(CompanionAPI.sessionEndpoints.last == base, "Editing an address never changes the accepted host")
        precondition(switchingStore.windows(hostID: hostID) == [terminal])

        let otherTarget = ConnectedHost(id: "host-2", endpoint: otherBase)
        let lateSession = HostSession(id: "late", workspaceId: "workspace", profile: nil,
            title: "Stale", cwd: "/old", status: "running")
        CompanionAPI.sessions[base.host!] = [lateSession]
        for fail in [false, true] {
            try accept(target, in: switching.launcher.connection)
            var releaseSessions: CheckedContinuation<Void, Never>?
            CompanionAPI.beforeSessions = {
                await withCheckedContinuation { releaseSessions = $0 }
                if fail { throw CompanionError(message: "Old host needs pairing", statusCode: 401) }
            }
            let oldRefresh = Task { await switching.launcher.refreshHostCatalog() }
            await until { releaseSessions != nil }
            try accept(otherTarget, in: switching.launcher.connection)
            releaseSessions!.resume()
            await oldRefresh.value
            precondition(switching.terminalPayload(for: lateSession.id) == nil)
            precondition(!switching.launcher.needsPairing, "A stale failure cannot change the new host's pairing state")
        }
        await switching.launcher.refreshHostCatalog()
        precondition(switchingStore.windows(hostID: "host-2") == [otherWindow])
        switching.close(reference, dismiss: false)
        await until { CompanionAPI.layouts[base.host!]!.windows.isEmpty }
        precondition(CompanionAPI.layouts[otherBase.host!]!.windows == [otherWindow], "Closing on one Mac never changes another Mac's layout")
        print("PASS: accepted hosts stay paired with endpoints; stale replies and failures cannot cross hosts")
    }

    @MainActor
    static func accept(_ target: ConnectedHost, in connection: HostConnection) throws {
        try connection.accept(CompanionHealthResponse(ok: true, hostId: target.id, paired: true, protocolVersion: 1,
            name: "Fixture", version: "1", hostname: "fixture", localHostName: "fixture", controlOrigin: target.endpoint.absoluteString,
            bonjourServiceType: nil, cwd: "/", logFilePath: "", workspacePaths: nil), endpoint: target.endpoint)
    }

    @MainActor
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Condition timed out")
    }
}
