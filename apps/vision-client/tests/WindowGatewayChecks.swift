import Foundation

// No discovery or process launch in these checks. Production gateway/persistence/
// launcher code runs against a controllable transport, including delayed replies.
@MainActor
enum Fixture {
    static var layouts: [String: WindowLayout] = [:]
    static var beforePut: (() async -> Void)?
    static var beforePreview: (() async -> Void)?
    static var frontends: [[String: Any]] = []
    static var nativeWindows: [String: Any]?
    static var beforeFrontends: (() async throws -> Void)?
    static var beforeSessions: (() async throws -> Void)?
    static var sessions: [String: [HostSession]] = [:]
    static var sessionEndpoints: [URL] = []
    static var replyVersion = 1
    static var putReplyVersion = 1
    static var loseReply = false
    static var previewPort = 12345
    static var requests: [String] = []
    static var inputBodies: [Data] = []
    static var loseInputReply = false
    static var beforeEndSessionReply: (() async throws -> Void)?
    static var beforeRenameReply: (() async throws -> Void)?
    static var api: CompanionClient {
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials(), exchange: exchange)
        let base = URL(string: "http://fixture.invalid:7777")!
        try! client.accept(fixtureHealth("host-1", endpoint: base), endpoint: base, authenticated: true)
        return client
    }
    static func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await reply(request) }
        catch let error as CompanionError where error.statusCode != nil {
            return try json(["error": error.message], for: request, status: error.statusCode!)
        }
    }
    private static func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let base = origin(request.url!)
        let path = request.url!.path, method = request.httpMethod ?? "GET", body = request.httpBody
        requests.append("\(method) \(path)")
        if method == "DELETE", path.hasPrefix("/api/sessions/") {
            if let callback = beforeEndSessionReply { beforeEndSessionReply = nil; try await callback() }
            let key = base.host!, id = String(path.dropFirst("/api/sessions/".count))
            sessions[key]?.removeAll { $0.id == id }
            return try json(["ok": true], for: request)
        }
        if path == "/api/workspaces" || (method == "PATCH" && path.hasPrefix("/api/workspaces/")) {
            let key = base.host!
            if method == "PATCH" {
                let id = String(path.dropFirst("/api/workspaces/".count))
                let input = try JSONSerialization.jsonObject(with: body!) as! [String: String]
                for index in sessions[key, default: []].indices where sessions[key]![index].workspaceId == id {
                    sessions[key]![index].workspaceName = input["name"]
                }
            }
            let workspaces: [[String: Any]] = (sessions[key] ?? []).map { session in
                ["workspaceId": session.workspaceId, "repo": ["nameWithOwner": "test/project", "isPrivate": false, "owner": ["avatarUrl": ""]],
                    "branchName": "unchanged", "name": session.workspaceName ?? "Default", "existsOnDisk": true]
            }
            return try json(method == "PATCH" ? ["workspace": workspaces[0]] : ["workspaces": workspaces], for: request)
        }
        if method == "PATCH", path.hasPrefix("/api/sessions/") {
            let key = base.host!, id = String(path.dropFirst("/api/sessions/".count))
            guard let index = sessions[key]?.firstIndex(where: { $0.id == id }) else {
                throw CompanionError(message: "Missing session", statusCode: 404)
            }
            let body = try JSONSerialization.jsonObject(with: body!) as! [String: String]
            sessions[key]![index].name = body["name"]
            let response = sessionJSON(sessions[key]![index])
            if let callback = beforeRenameReply { beforeRenameReply = nil; try await callback() }
            return try json(["session": response], for: request)
        }
        if method == "POST", path.hasSuffix("/input") {
            inputBodies.append(body!)
            if loseInputReply { loseInputReply = false; throw URLError(.networkConnectionLost) }
            return try json(["ok": true], for: request)
        }
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
            return response(try JSONEncoder().encode(reply), for: request)
        }
        if path == "/api/sessions" {
            sessionEndpoints.append(base)
            if let callback = beforeSessions { beforeSessions = nil; try await callback() }
            return try json(["sessions": (sessions[base.host!] ?? []).map(sessionJSON)], for: request)
        }
        if path == "/api/frontends" {
            if let callback = beforeFrontends { beforeFrontends = nil; try await callback() }
            var result: [String: Any] = ["frontends": frontends, "warning": "Frontend fixture"]
            if let nativeWindows { result["windows"] = nativeWindows }
            return try json(result, for: request)
        }
        if path == "/api/window-previews/open" {
            if let callback = beforePreview { beforePreview = nil; await callback() }
            return try json(["source": (nativeWindows!["sources"] as! [[String: Any]])[0]], for: request)
        }
        if path == "/api/frontends/open" {
            let port = previewPort
            if let callback = beforePreview { beforePreview = nil; await callback() }
            return response(Data("""
                {"frontend":{"id":"web","hostname":"localhost","url":"https://localhost/app","transport":"gateway"},
                 "exposedPort":\(port),"accessToken":"transient-secret","gatewayScheme":"https","certificateAuthority":"public-ca"}
                """.utf8), for: request)
        }
        throw CompanionError(message: "Unexpected request: \(method) \(path)")
    }
}

@main
struct WindowGatewayChecks {
    @MainActor
    static func main() async throws {
        defer { CompanionTestPreferences.clean() }
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
        let target = ConnectedHost(id: hostID)
        let reference = WindowReference(hostID: hostID, window: terminal)
        let store = WindowPersistence(defaults: defaults)
        try store.set(reference, isOpen: true)
        // Process replacement before upload still has its unacknowledged open.
        let restored = WindowPersistence(defaults: defaults)
        precondition(restored.windows(hostID: hostID) == [terminal])
        try await restored.synchronize(hostID: hostID, client: Fixture.api)
        let fromMac = WindowPersistence(defaults: defaults)
        try await fromMac.synchronize(hostID: hostID, client: Fixture.api)
        precondition(fromMac.windows(hostID: hostID) == [terminal])
        precondition(fromMac.windows(hostID: "another-mac").isEmpty)

        Fixture.replyVersion = 2
        do { try await fromMac.synchronize(hostID: hostID, client: Fixture.api); preconditionFailure("Expected unsupported version") }
        catch {}
        Fixture.replyVersion = 1
        try fromMac.set(reference, isOpen: true)
        Fixture.putReplyVersion = 2
        do { try await fromMac.synchronize(hostID: hostID, client: Fixture.api); preconditionFailure("Expected unsupported acknowledgement") }
        catch {}
        precondition(WindowPersistence(defaults: defaults).windows(hostID: hostID) == [terminal], "An unsupported acknowledgement cannot clear pending intent")
        Fixture.putReplyVersion = 1
        try await fromMac.synchronize(hostID: hostID, client: Fixture.api)

        var release: CheckedContinuation<Void, Never>?
        Fixture.beforePut = { await withCheckedContinuation { release = $0 } }
        try fromMac.set(reference, isOpen: true)
        let upload = Task { try await fromMac.synchronize(hostID: hostID, client: Fixture.api) }
        await until { release != nil }
        try fromMac.set(reference, isOpen: false)
        release!.resume()
        try await upload.value
        precondition(fromMac.windows(hostID: hostID).isEmpty, "A late open acknowledgement cannot erase a newer close")
        Fixture.loseReply = true
        do { try await fromMac.synchronize(hostID: hostID, client: Fixture.api); preconditionFailure("Expected dropped reply") }
        catch {}
        let afterLostReply = WindowPersistence(defaults: defaults)
        precondition(afterLostReply.windows(hostID: hostID).isEmpty)
        try await afterLostReply.synchronize(hostID: hostID, client: Fixture.api)
        precondition(Fixture.layouts[base.host!]!.windows.isEmpty)

        try afterLostReply.set(reference, isOpen: true)
        Fixture.beforePut = {
            var concurrent = Fixture.layouts[base.host!]!
            concurrent.windows = [preview]
            concurrent.revision += 1
            Fixture.layouts[base.host!] = concurrent
        }
        do { try await afterLostReply.synchronize(hostID: hostID, client: Fixture.api); preconditionFailure("Expected revision conflict") }
        catch {}
        try await afterLostReply.synchronize(hostID: hostID, client: Fixture.api)
        precondition(Set(afterLostReply.windows(hostID: hostID)) == Set([terminal, preview]), "Retry rebases only local intent, preserving other saved windows")
        print("PASS: restart, in-flight close, lost replies, host isolation, and revision conflicts preserve intent")

        let gateway = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
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
        let session = HostSession(id: terminal.id, workspaceId: "workspace",
            title: "Shell", cwd: "/project")
        let closedSession = HostSession(id: "closed-session", workspaceId: "workspace",
            title: "Detached", cwd: "/project")
        await gateway.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session, closedSession]), target)
        await until { gateway.previewPayload(for: preview.id) != nil }
        precondition(opened == [preview.id], "An OS-restored scene is reused; only missing windows are opened")
        precondition(gateway.terminalPayload(for: terminal.id) != nil)
        precondition(gateway.terminalSessions.first?.id == terminal.id)
        precondition(gateway.terminalSessions.first?.isFocused == true, "Presence observed before payload resolution is retained")
        precondition(gateway.receiveTerminalNotification(id: terminal.id, sequence: 1, serviceInstanceID: "test"))
        precondition(gateway.hasUnreadNotification(terminal.id))
        gateway.readTerminalNotifications(id: "other-window")
        precondition(gateway.hasUnreadNotification(terminal.id))
        gateway.readTerminalNotifications(id: terminal.id)
        precondition(!gateway.hasUnreadNotification(terminal.id))
        precondition(!gateway.receiveTerminalNotification(id: terminal.id, sequence: 1, serviceInstanceID: "test"))
        precondition(!gateway.hasUnreadNotification(terminal.id), "reattachment cannot re-alert after selection")
        let lastFocused = gateway.terminalSessions.first!.lastFocusedAt
        gateway.openLauncher()
        precondition(commands.last == .openLauncher)
        precondition(gateway.previewPayload(for: preview.id)?.url?.scheme == "https")
        Fixture.previewPort = 12346
        gateway.reload(id: preview.id)
        precondition(gateway.reloadToken(for: preview.id) == 1, "Existing content reloads without waiting for the companion")
        await until { gateway.previewPayload(for: preview.id)?.url?.port == 12346 }
        precondition(gateway.receiveTerminalNotification(id: terminal.id, sequence: 2, serviceInstanceID: "test"))
        gateway.reload(id: terminal.id)
        precondition(gateway.hasUnreadNotification(terminal.id), "content reload retains unread state")
        precondition(gateway.reloadToken(for: terminal.id) == 1)
        precondition(opened == [preview.id], "Content reload must not reopen scenes or open detached sessions")
        gateway.observe(id: terminal.id, isPresented: false, isFocused: false)
        gateway.detachPresenter(presenterID)
        await gateway.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        precondition(Fixture.layouts[base.host!]!.windows.count == 2, "Background and disconnect never close saved windows")
        precondition(opened.count == 1)
        precondition(gateway.terminalSessions.first?.isPresented == false)
        precondition(gateway.terminalSessions.first?.isFocused == false)
        precondition(gateway.terminalSessions.first?.lastFocusedAt == lastFocused, "Catalog refresh does not reset scene activity")
        gateway.discardScene(WindowReference(hostID: hostID, window: preview), remainingScenes: [])
        await until { Fixture.layouts[base.host!]!.windows.count == 1 }
        precondition(dismissed.isEmpty, "System discard must not recursively request another dismissal")

        // Restored scenes may be discarded before connection/bootstrap completes.
        let next = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
        next.discardScene(reference, remainingScenes: [])
        next.attachPresenter(UUID()) { if case .open(let window) = $0 { opened.append(window.id) } }
        await next.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        await until { Fixture.layouts[base.host!]!.windows.isEmpty }
        precondition(opened == [preview.id], "A cold-start discard must win over the remote snapshot")
        precondition(!Fixture.requests.contains(where: { $0.contains("/sessions") }), "Recovery never spawns replacement processes")
        print("PASS: independent scene recovery, deduplicated presentation, and explicit closure")

        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal])
        let missing = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
        var missingOpens = 0
        missing.attachPresenter(UUID()) { if case .open = $0 { missingOpens += 1 } }
        await missing.client.onSessionSnapshot?(HostSessionsResponse(sessions: []), target)
        await missing.client.onSessionSnapshot?(HostSessionsResponse(sessions: []), target)
        precondition(missingOpens == 1 && missing.terminalPayload(for: terminal.id) == nil)
        precondition(missing.message(for: terminal.id).contains("no longer available"))
        let background = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
        background.observe(id: terminal.id, isPresented: false, isFocused: false)
        background.attachPresenter(UUID()) { if case .open = $0 { missingOpens += 1 } }
        await background.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        precondition(missingOpens == 1, "A restored background scene must not be pulled forward")
        print("PASS: missing sessions stay unavailable and restored background scenes stay in place")

        // The reopened replacement is in UIKit's archived open-session inventory,
        // but no view has connected/observed yet. A stale discard must not queue
        // an offline close that later removes the replacement from the Mac layout.
        let archiveSuite = "ArchivedReplacement.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveSuite)!
        defer { archiveDefaults.removePersistentDomain(forName: archiveSuite) }
        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal])
        let archived = WindowGateway(persistence: WindowPersistence(defaults: archiveDefaults), client: Fixture.api)
        archived.discardScene(reference, remainingScenes: [reference])
        await archived.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        precondition(Fixture.layouts[base.host!]!.windows == [terminal], "An archived replacement must survive a delayed discard of its old scene")
        let afterArchiveRestart = WindowGateway(persistence: WindowPersistence(defaults: archiveDefaults), client: Fixture.api)
        await afterArchiveRestart.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        precondition(Fixture.layouts[base.host!]!.windows == [terminal], "Ignoring an old discard must not leave a persisted close in the outbox")
        // Matching content on another Mac is not a replacement for this window.
        archived.discardScene(reference, remainingScenes: [WindowReference(hostID: "another-host", window: terminal)])
        await until { Fixture.layouts[base.host!]!.windows.isEmpty }
        print("PASS: archived replacement sessions survive delayed cold-start discards; genuine final closes still persist")

        // Closing a preview while its gateway is being resolved cannot resurrect it.
        Fixture.layouts[base.host!] = WindowLayout(windows: [preview])
        var releasePreview: CheckedContinuation<Void, Never>?
        var finishedPreview = false
        Fixture.beforePreview = {
            await withCheckedContinuation { releasePreview = $0 }
            finishedPreview = true
        }
        let latePreview = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
        let refresh = Task { await latePreview.client.onSessionSnapshot?(HostSessionsResponse(sessions: []), target) }
        await until { releasePreview != nil }
        latePreview.close(WindowReference(hostID: hostID, window: preview), dismiss: false)
        await until { Fixture.layouts[base.host!]!.windows.isEmpty }
        releasePreview!.resume()
        await refresh.value
        await until { finishedPreview }
        precondition(latePreview.previewPayload(for: preview.id) == nil)
        await latePreview.client.onSessionSnapshot?(HostSessionsResponse(sessions: []), target)
        precondition(Fixture.layouts[base.host!]!.windows.isEmpty)
        let encoded = try JSONEncoder().encode(Fixture.layouts[base.host!]!)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("transient-secret"))
        print("PASS: late preview resolution cannot resurrect a closed window")

        // A new HTTP process refreshes preview routing and presented terminal
        // documents, preserving desired windows and terminal process identity.
        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal, preview])
        let restarted = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: Fixture.api)
        await restarted.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session, closedSession], companionInstanceId: "before"), target)
        restarted.observe(id: terminal.id, isPresented: true, isFocused: true)
        precondition(restarted.reloadToken(for: terminal.id) == 0)
        await until { restarted.previewPayload(for: preview.id) != nil }
        Fixture.previewPort = 23456
        await restarted.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session, closedSession], companionInstanceId: "after"), target)
        await until { restarted.previewPayload(for: preview.id)?.urlString.contains(":23456/") == true }
        precondition(restarted.terminalPayload(for: session.id) != nil)
        precondition(restarted.reloadToken(for: terminal.id) == 1, "A new HTTP process refreshes terminal authentication and transport in the same scene")
        precondition(restarted.reloadToken(for: closedSession.id) == 0, "Detached sessions must not load content or launch processes")
        await restarted.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session], companionInstanceId: "after"), target)
        precondition(restarted.reloadToken(for: terminal.id) == 1, "Repeated snapshots cannot keep reloading a healthy terminal")
        precondition(Fixture.layouts[base.host!]!.windows.count == 2)
        try accept(target, in: restarted.client)
        Fixture.beforeSessions = { throw CompanionError(message: "Session service unavailable", statusCode: 503) }
        Fixture.requests.removeAll()
        await restarted.client.refreshSessions()
        await restarted.client.refreshFrontends(hostID: hostID)
        precondition(Fixture.requests.contains("GET /api/frontends"), "Session failure cannot block frontend refresh")
        precondition(restarted.client.frontends(for: hostID).warning == "Frontend fixture")
        precondition(restarted.terminalPayload(for: session.id) != nil, "A service outage is not an empty snapshot")
        precondition(Fixture.layouts[base.host!]!.windows.count == 2)
        Fixture.sessions[base.host!] = [session]
        Fixture.beforeFrontends = { throw CompanionError(message: "Frontend unavailable", statusCode: 503) }
        await restarted.client.refreshSessions()
        await restarted.client.refreshFrontends(hostID: hostID)
        precondition(restarted.client.frontends(for: hostID).warning == "GET /api/frontends — HTTP 503: Frontend unavailable")
        Fixture.beforeSessions = { throw CompanionError(message: "Pair again", statusCode: 401) }
        Fixture.requests.removeAll()
        await restarted.client.refreshSessions()
        await restarted.client.refreshFrontends(hostID: hostID)
        precondition(restarted.client.needsPairing && !Fixture.requests.contains("GET /api/frontends"))
        print("PASS: companion restarts and independent catalog failures preserve window intent and authentication")

        gateway.attachPresenter(presenterID) { commands.append($0) }
        gateway.close(reference)
        precondition(commands.last == .close(terminal))
        await gateway.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        print("PASS: shared layout contract and typed scene commands preserve identity")

        // Poll the accepted connection while the next address is being edited.
        let otherBase = URL(string: "http://other.invalid:7777")!
        let otherWindow = WindowRecord(id: "terminal-2", kind: .terminal, targetID: "terminal-2")
        let otherSession = HostSession(id: otherWindow.id, workspaceId: "workspace",
            title: "Other shell", cwd: "/other")
        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal])
        Fixture.layouts[otherBase.host!] = WindowLayout(windows: [otherWindow])
        Fixture.sessions = [base.host!: [session], otherBase.host!: [otherSession]]
        let switchingStore = WindowPersistence(defaults: defaults)
        let switching = WindowGateway(persistence: switchingStore, client: Fixture.api)
        try accept(target, in: switching.client)
        switching.client.host = otherBase.absoluteString
        await switching.client.refreshSessions()
        precondition(Fixture.sessionEndpoints.last == base, "Editing an address never changes the accepted host")
        precondition(switchingStore.windows(hostID: hostID) == [terminal])

        let otherTarget = ConnectedHost(id: "host-2")
        let lateSession = HostSession(id: "late", workspaceId: "workspace",
            title: "Stale", cwd: "/old")
        Fixture.sessions[base.host!] = [lateSession]
        for fail in [false, true] {
            try accept(target, in: switching.client)
            var releaseSessions: CheckedContinuation<Void, Never>?
            Fixture.beforeSessions = {
                await withCheckedContinuation { releaseSessions = $0 }
                if fail { throw CompanionError(message: "Old host needs pairing", statusCode: 401) }
            }
            let oldRefresh = Task { await switching.client.refreshSessions() }
            await until { releaseSessions != nil }
            try accept(otherTarget, in: switching.client)
            releaseSessions!.resume()
            await oldRefresh.value
            precondition(switching.terminalPayload(for: lateSession.id) == nil)
            precondition(!switching.client.needsPairing, "A stale failure cannot change the new host's pairing state")
        }
        await switching.client.refreshSessions()
        precondition(switchingStore.windows(hostID: "host-2") == [otherWindow])
        switching.close(reference, dismiss: false)
        await until { Fixture.layouts[base.host!]!.windows.isEmpty }
        precondition(Fixture.layouts[otherBase.host!]!.windows == [otherWindow], "Closing on one Mac never changes another Mac's layout")
        print("PASS: accepted hosts stay paired with endpoints; stale replies and failures cannot cross hosts")

        // Voice uses the existing gateway and stable session ID, including retries.
        let voiceStore = WindowPersistence(defaults: defaults)
        try voiceStore.set(reference, isOpen: true)
        let voiceGateway = WindowGateway(persistence: voiceStore, client: Fixture.api)
        await voiceGateway.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session]), target)
        voiceGateway.observe(id: terminal.id, isPresented: true, isFocused: true)
        voiceGateway.updateTerminalLoadState(id: terminal.id, loadState: .loaded)
        precondition(voiceGateway.canReceiveVoice(terminal.id))
        let input = TerminalVoiceCommand(targetID: terminal.id, commandID: UUID().uuidString, text: "hello")
        Fixture.loseInputReply = true
        try await voiceGateway.submitVoiceInput(input)
        precondition(Fixture.inputBodies.count == 2 && Fixture.inputBodies[0] == Fixture.inputBodies[1])
        let body = try JSONSerialization.jsonObject(with: Fixture.inputBodies[0]) as! [String: Any]
        precondition(body["commandId"] as? String == input.commandID && body["text"] as? String == "hello")
        precondition(body["sendReturn"] as? Bool == true)
        precondition(Fixture.requests.last == "POST /api/sessions/\(terminal.id)/input")
        voiceGateway.observe(id: terminal.id, isPresented: false, isFocused: false)
        precondition(!voiceGateway.canReceiveVoice(terminal.id))
        do { try await voiceGateway.submitVoiceInput(input); preconditionFailure("Disconnected scenes cannot receive voice") }
        catch {}
        precondition(Fixture.inputBodies.count == 2)
        voiceGateway.observe(id: terminal.id, isPresented: true, isFocused: true)
        voiceGateway.close(reference, dismiss: false)
        precondition(!voiceGateway.canReceiveVoice(terminal.id), "Close intent takes effect before native disappearance")
        print("PASS: voice input resolves through the gateway, retries identical commands, and respects scene availability and close intent")

        let names = try JSONDecoder().decode(HostSessionsResponse.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))).sessions
        precondition(names[0].name == "Fix-the-login-flow" && names[1].name == nil)
        let nameSuite = "TerminalNameChecks.\(UUID().uuidString)"
        let nameDefaults = UserDefaults(suiteName: nameSuite)!
        defer { nameDefaults.removePersistentDomain(forName: nameSuite) }
        let nameBase = URL(string: "http://names.invalid:7777")!
        let nameTarget = ConnectedHost(id: "names-host")
        Fixture.sessions[nameBase.host!] = names
        Fixture.layouts[nameBase.host!] = WindowLayout(windows: names.map {
            WindowRecord(id: $0.id, kind: .terminal, targetID: $0.id)
        })
        let naming = WindowGateway(persistence: WindowPersistence(defaults: nameDefaults), client: Fixture.api)
        naming.observe(id: names[1].id, isPresented: true, isFocused: true)
        try accept(nameTarget, in: naming.client)
        await naming.client.onSessionSnapshot?(HostSessionsResponse(sessions: names), nameTarget)
        naming.updateTerminalLoadState(id: names[1].id, loadState: .loaded)
        precondition(naming.terminalPayload(for: names[0].id)?.title == "Fix-the-login-flow")
        precondition(naming.terminalPayload(for: names[1].id)?.title == "Terminal • project",
            "Older companions and unnamed sessions retain their original title")
        for index in Fixture.sessions[nameBase.host!]!.indices {
            Fixture.sessions[nameBase.host!]![index].projectName = "project"
            Fixture.sessions[nameBase.host!]![index].workspaceName = "Default"
        }
        naming.updateTerminalLoadState(id: names[1].id, loadState: .loading("Legacy renderer reconnecting"))
        precondition(!naming.canReceiveVoice(names[1].id) && naming.canRename(names[1].id),
            "Legacy terminal input readiness must not block metadata naming")
        try await naming.rename(id: names[1].id, name: "Shared workspace", target: .workspace)
        naming.updateTerminalLoadState(id: names[1].id, loadState: .loaded)
        precondition(names.allSatisfy { naming.terminalPayload(for: $0.id)?.workspaceName == "Shared-workspace" })
        precondition(naming.terminalPayload(for: names[0].id)?.title == "Fix-the-login-flow")
        precondition(naming.launcher.recentWorkspaces.first?.name == "Shared-workspace")
        precondition(naming.terminalPayload(for: names[0].id)?.displayTitle == "project / Shared-workspace / Fix-the-login-flow")
        precondition(!Fixture.requests.contains(where: { $0.hasPrefix("POST /api/workspaces/") }), "Workspace naming cannot create sessions")
        print("PASS: workspace voice naming refreshes all sibling windows and project catalog without changing window names or creating processes")
        var nameCommands: [WindowCommand] = []
        naming.attachPresenter(UUID()) { nameCommands.append($0) }
        nameCommands.removeAll()
        try await naming.rename(id: names[1].id, name: "  Fix\tthe\nsearch  ")
        precondition(naming.terminalPayload(for: names[1].id)?.title == "Fix-the-search")
        precondition(naming.terminalSessions.contains(where: { $0.payload.title == "Fix-the-search" }))
        precondition(Fixture.sessions[nameBase.host!]![1].name == "Fix-the-search")
        var releaseName: CheckedContinuation<Void, Never>?
        Fixture.beforeRenameReply = { await withCheckedContinuation { releaseName = $0 } }
        let olderRename = Task { try await naming.rename(id: names[1].id, name: "Older name") }
        await until { releaseName != nil }
        try await naming.rename(id: names[1].id, name: "Newest name")
        releaseName!.resume()
        try await olderRename.value
        precondition(naming.terminalPayload(for: names[1].id)?.title == "Newest-name", "Late rename replies cannot replace a newer name")
        await naming.client.onSessionSnapshot?(HostSessionsResponse(sessions: Fixture.sessions[nameBase.host!]!), nameTarget)
        let recoveredName = WindowGateway(persistence: WindowPersistence(defaults: nameDefaults), client: Fixture.api)
        try accept(nameTarget, in: recoveredName.client)
        await recoveredName.client.onSessionSnapshot?(HostSessionsResponse(sessions: Fixture.sessions[nameBase.host!]!), nameTarget)
        precondition(recoveredName.terminalPayload(for: names[1].id)?.title == "Newest-name", "Saved names recover without the launcher")
        precondition(nameCommands.isEmpty, "Rename must not reopen, close, or replace native scenes")
        releaseName = nil
        Fixture.beforeRenameReply = { await withCheckedContinuation { releaseName = $0 } }
        let endedRename = Task { try await naming.rename(id: names[1].id, name: "Ended session") }
        await until { releaseName != nil }
        Fixture.sessions[nameBase.host!]!.removeAll { $0.id == names[1].id }
        await naming.client.onSessionSnapshot?(HostSessionsResponse(sessions: Fixture.sessions[nameBase.host!]!), nameTarget)
        releaseName!.resume()
        try await endedRename.value
        precondition(naming.terminalPayload(for: names[1].id) == nil && !naming.canReceiveVoice(names[1].id),
            "An old rename acknowledgement cannot resurrect a session already reported as ended")
        naming.close(id: names[1].id)
        let requestCount = Fixture.requests.count
        do { try await naming.rename(id: names[1].id, name: "Closed"); preconditionFailure("Closed windows cannot rename") }
        catch {}
        precondition(!Fixture.requests.dropFirst(requestCount).contains(where: { $0.hasPrefix("PATCH") }))
        print("PASS: shared names and legacy fallback reach launcher payloads, reject stale replies, and recover without replacing scenes or processes")

        try await checkClosingAndEnding()

        let routeSuite = "WindowRouteChecks.\(UUID().uuidString)"
        let routeDefaults = UserDefaults(suiteName: routeSuite)!
        defer { routeDefaults.removePersistentDomain(forName: routeSuite) }
        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal, preview])
        let routed = WindowGateway(persistence: WindowPersistence(defaults: routeDefaults), client: Fixture.api)
        routed.observe(id: terminal.id, isPresented: true, isFocused: false)
        let sameInstance = HostSessionsResponse(sessions: [session], companionInstanceId: "same-service")
        await routed.client.onSessionSnapshot?(sameInstance, routed.client.current!)
        await until { routed.previewPayload(for: preview.id) != nil }
        var routeCommands: [WindowCommand] = []
        routed.attachPresenter(UUID()) { routeCommands.append($0) }
        let presentedCount = routeCommands.count
        let routeReloads = routed.reloadToken(for: terminal.id)
        Fixture.layouts[otherBase.host!] = Fixture.layouts[base.host!]
        Fixture.previewPort = 34567
        try routed.client.accept(fixtureHealth(hostID, endpoint: otherBase), endpoint: otherBase, authenticated: true)
        await routed.client.onSessionSnapshot?(sameInstance, routed.client.current!)
        await until { routed.previewPayload(for: preview.id)?.url?.host == otherBase.host }
        precondition(routed.terminalPayload(for: terminal.id)?.url?.host == otherBase.host)
        precondition(routed.reloadToken(for: terminal.id) > routeReloads)
        precondition(routed.reference(for: terminal.id)?.hostID == hostID && routeCommands.count == presentedCount)
        print("PASS: route replacement refreshes terminal and preview content while preserving host, session, and scene identity")

        // A replacement resolution must not wait for a cancelled request to finish.
        for closeAndReopen in [false, true] {
            var release: CheckedContinuation<Void, Never>?
            var finished = false
            Fixture.beforePreview = {
                await withCheckedContinuation { release = $0 }
                finished = true
            }
            routed.reload(id: preview.id)
            await until { release != nil }
            let previous = routed.previewPayload(for: preview.id)
            let commandsBefore = routeCommands.count
            var releaseLatest: CheckedContinuation<Void, Never>?
            Fixture.beforePreview = { await withCheckedContinuation { releaseLatest = $0 } }
            Fixture.previewPort += 1
            let expectedPort = Fixture.previewPort
            if closeAndReopen {
                routed.close(id: preview.id)
                try routed.open(id: preview.id)
            } else {
                routed.reload(id: preview.id)
                precondition(routed.previewPayload(for: preview.id)?.urlString == previous?.urlString,
                    "Resolving a replacement keeps the existing WebView content available")
            }
            await until { releaseLatest != nil }
            release!.resume()
            await until { finished }
            let reads = Fixture.requests.filter { $0 == "POST /api/frontends/open" }.count
            await routed.client.onSessionSnapshot?(sameInstance, routed.client.current!)
            precondition(Fixture.requests.filter { $0 == "POST /api/frontends/open" }.count == reads,
                "Finishing an old request cannot make recovery start a duplicate of the newer pending request")
            precondition(routeCommands.count == commandsBefore + (closeAndReopen ? 2 : 0),
                "Recovery must not add native opens or closes beyond the requested close/reopen")
            releaseLatest!.resume()
            await until { routed.previewPayload(for: preview.id)?.url?.port == expectedPort }
            precondition(routed.previewPayload(for: preview.id)?.url?.port == expectedPort,
                "A late resolution cannot replace newer content or clear its pending work")
        }
        print("PASS: repeated reload and close/reopen replace stalled preview work without losing content or accepting late results")

        // A connection-method switch removes the live documents, not the scenes
        // or saved intent. Exercise it with a preview resolution still in flight.
        var releaseSwitch: CheckedContinuation<Void, Never>?
        Fixture.beforePreview = { await withCheckedContinuation { releaseSwitch = $0 } }
        routed.reload(id: preview.id)
        await until { releaseSwitch != nil }
        let commandsBeforeSwitch = routeCommands.count
        let mutationsBeforeSwitch = Fixture.requests.filter { $0.hasPrefix("POST /api/workspaces") || $0.hasPrefix("DELETE /api/sessions") }.count
        let retiringHostID = routed.client.current!.id
        await routed.client.setConnectionMethod(.direct)
        precondition(routed.previewPayload(for: preview.id) == nil)
        precondition(routed.terminalPayload(for: terminal.id) == nil)
        precondition(routeCommands.count == commandsBeforeSwitch, "Transport retirement never dismisses native scenes")
        let staleFrontend = try JSONDecoder().decode(FrontendSummary.self, from: Data("""
            {"id":"stale-preview","hostname":"example.com","url":"https://example.com","transport":"direct"}
            """.utf8))
        do {
            try routed.openPreview(staleFrontend, hostID: retiringHostID)
            preconditionFailure("A stale caller must not create a preview window during route retirement")
        } catch is CompanionError {}
        precondition(routed.reference(for: "\(retiringHostID):stale-preview") == nil)
        precondition(routeCommands.count == commandsBeforeSwitch)
        routed.close(id: preview.id)
        releaseSwitch?.resume()
        for _ in 0..<20 { await Task.yield() }
        precondition(routed.previewPayload(for: preview.id) == nil, "A late payload cannot revive the retired document")
        precondition(Fixture.requests.filter { $0.hasPrefix("POST /api/workspaces") || $0.hasPrefix("DELETE /api/sessions") }.count == mutationsBeforeSwitch,
            "Changing method or closing an unavailable preview must not create or end a process")
        print("PASS: method switch retires documents without scene/process mutation; late preview replies and explicit close stay closed")

        let unavailableSuite = "UnavailablePreviewChecks.\(UUID().uuidString)"
        let unavailableDefaults = UserDefaults(suiteName: unavailableSuite)!
        defer { unavailableDefaults.removePersistentDomain(forName: unavailableSuite); Fixture.frontends = [] }
        Fixture.layouts[base.host!] = WindowLayout(windows: [terminal, preview])
        let unavailable = WindowGateway(persistence: WindowPersistence(defaults: unavailableDefaults), client: Fixture.api)
        let unavailableTarget = unavailable.client.current!
        Fixture.frontends = [["id": preview.targetID, "hostname": "localhost", "url": "https://localhost/app", "transport": "gateway",
            "presentation": ["presentation": "web", "available": false, "reasonCode": "presentation_unsupported_on_route", "message": "Use Local Network for this preview", "alternatives": []]]]
        await unavailable.client.refreshFrontends(hostID: hostID)
        let opensBefore = Fixture.requests.filter { $0 == "POST /api/frontends/open" }.count
        for _ in 0..<4 { await unavailable.client.onSessionSnapshot?(sameInstance, unavailableTarget) }
        for _ in 0..<10 { await Task.yield() }
        precondition(Fixture.requests.filter { $0 == "POST /api/frontends/open" }.count == opensBefore,
            "A restored unavailable preview must not repeatedly invoke Open or produce 409/error logs")
        precondition(unavailable.previewPayload(for: preview.id) == nil && unavailable.message(for: preview.id) == "Use Local Network for this preview")
        precondition(unavailable.terminalPayload(for: terminal.id) != nil && unavailable.reference(for: preview.id) != nil,
            "Unavailable preview intent and independent terminal recovery survive")
        Fixture.frontends[0]["presentation"] = ["presentation": "web", "available": true, "alternatives": []]
        await unavailable.client.refreshFrontends(hostID: hostID)
        await unavailable.client.onSessionSnapshot?(sameInstance, unavailableTarget)
        await until { unavailable.previewPayload(for: preview.id) != nil }
        precondition(Fixture.requests.filter { $0 == "POST /api/frontends/open" }.count == opensBefore + 1,
            "A newly available catalog resolves the same saved preview exactly once")
        print("PASS: known unavailable previews retain intent without repeated Open requests, then recover when the catalog permits them")

        let nativeJSON = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        Fixture.nativeWindows = try JSONSerialization.jsonObject(with: nativeJSON) as? [String: Any]
        defer { Fixture.nativeWindows = nil }
        let nativeClient = Fixture.api
        let transport = CompanionTransportRoute.legacyLocalNetwork(base, token: "fixture-native-token")
        try nativeClient.accept(fixtureHealth(hostID, endpoint: base), endpoint: base, authenticated: true, transport: transport)
        let nativeGateway = WindowGateway(persistence: WindowPersistence(defaults: defaults), client: nativeClient)
        await nativeClient.refreshFrontends(hostID: hostID)
        let nativeSource = nativeClient.frontends(for: hostID).windows!.sources[0]
        try nativeGateway.openWindowPreview(nativeSource, hostID: hostID)
        let nativeID = "\(hostID):\(nativeSource.id)"
        await until { nativeGateway.previewPayload(for: nativeID)?.nativeWindow != nil }
        precondition(nativeGateway.reference(for: nativeID)?.window.kind == .preview)
        precondition(nativeGateway.previewPayload(for: nativeID)!.nativeWindow!.source.contentWidth == 390)
        let nativeRecord = nativeGateway.reference(for: nativeID)!
        let encodedNative = String(data: try JSONEncoder().encode(nativeRecord), encoding: .utf8)!
        precondition(!encodedNative.contains("token") && !encodedNative.contains("http") && !encodedNative.contains("contentWidth"))
        let opens = Fixture.requests.filter { $0 == "POST /api/window-previews/open" }.count
        nativeGateway.observe(id: nativeID, isPresented: false, isFocused: false)
        precondition(nativeGateway.reference(for: nativeID) != nil, "View disconnect is not native preview close")
        Fixture.nativeWindows!["presentation"] = ["presentation": "window", "available": false, "reasonCode": "desktop_locked", "message": "Unlock Mac", "alternatives": []]
        await nativeClient.refreshFrontends(hostID: hostID)
        nativeGateway.reload(id: nativeID)
        for _ in 0..<20 { await Task.yield() }
        precondition(Fixture.requests.filter { $0 == "POST /api/window-previews/open" }.count == opens,
            "Known unavailable native windows do not repeatedly request capture")
        nativeGateway.close(id: nativeID)
        await until { !Fixture.layouts[base.host!, default: WindowLayout()].windows.contains(where: { $0.id == nativeID }) }
        precondition(nativeGateway.previewPayload(for: nativeID) == nil)
        precondition(!Fixture.requests.contains(where: { $0.contains("window-previews/end") }), "Viewer closure never quits a source app")
        print("PASS: native preview shares the gateway, persists only source identity, respects capture availability, and separates disconnect from close")

        // A late disappearance after explicit close is not a new scene. Remote
        // desired-open must still be deliverable through a remaining presenter.
        Fixture.nativeWindows!["presentation"] = ["presentation": "window", "available": true, "alternatives": []]
        await nativeClient.refreshFrontends(hostID: hostID)
        nativeGateway.observe(id: nativeID, isPresented: false, isFocused: false)
        var remoteOpens = 0
        nativeGateway.attachPresenter(UUID()) { command in
            if case .open(let record) = command, record.id == nativeID { remoteOpens += 1 }
        }
        Fixture.layouts[base.host!]!.windows.append(nativeRecord.window)
        Fixture.layouts[base.host!]!.revision += 1
        await nativeClient.onSessionSnapshot?(sameInstance, nativeClient.current!)
        await until { nativeGateway.previewPayload(for: nativeID) != nil }
        precondition(remoteOpens == 1, "Late hidden observations cannot swallow a later remote reopen")

        let unpairedBase = URL(string: "http://unpaired.invalid:7777")!
        try nativeClient.accept(fixtureHealth("unpaired-host", endpoint: unpairedBase), endpoint: unpairedBase, authenticated: false)
        try nativeClient.accept(fixtureHealth(hostID, endpoint: base), endpoint: base, authenticated: true, transport: transport)
        await nativeClient.refreshFrontends(hostID: hostID)
        await nativeClient.onSessionSnapshot?(sameInstance, nativeClient.current!)
        precondition(nativeGateway.persistenceError == nil, "An unrelated discovered unpaired Mac must not poison paired-Mac window recovery")

        // Native scene restoration can precede layout arrival. Its existing
        // reference must still render the current route's availability reason.
        let emptySuite = "RestoredPreviewAvailability.\(UUID().uuidString)"
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        Fixture.layouts[base.host!] = WindowLayout()
        Fixture.nativeWindows!["presentation"] = ["presentation": "window", "available": false,
            "reasonCode": "presentation_unsupported_on_route", "message": "Older companion: native preview unavailable on Direct", "alternatives": []]
        let restoredNative = WindowGateway(persistence: WindowPersistence(defaults: emptyDefaults), client: nativeClient)
        restoredNative.remember(nativeRecord)
        restoredNative.observe(id: nativeID, isPresented: true, isFocused: false)
        await nativeClient.refreshFrontends(hostID: hostID)
        await nativeClient.onSessionSnapshot?(sameInstance, nativeClient.current!)
        precondition(restoredNative.message(for: nativeID) == "Older companion: native preview unavailable on Direct",
            "A restored scene must not claim to reconnect to an unsupported preview route")
        precondition(Fixture.layouts[base.host!]!.windows.isEmpty, "Availability repair must not create desired-open intent")
        print("PASS: remote reopen survives late observations, unpaired Macs cannot poison recovery, and restored previews show route availability")

    }

    @MainActor
    static func checkClosingAndEnding() async throws {
        let suite = "WindowGatewayStopChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = URL(string: "http://stop-fixture.invalid:7777")!
        let target = ConnectedHost(id: "stop-host")
        let window = WindowRecord(id: "stop-session", kind: .terminal, targetID: "stop-session")
        let reference = WindowReference(hostID: target.id, window: window)
        let session = HostSession(id: window.id, workspaceId: "workspace",
            title: "Shell", cwd: "/project")
        let other = HostSession(id: "other-session", workspaceId: "workspace",
            title: "Other shell", cwd: "/project")
        Fixture.layouts[base.host!] = WindowLayout(windows: [window])
        Fixture.sessions[base.host!] = [session, other]
        let store = WindowPersistence(defaults: defaults)
        try store.set(reference, isOpen: true)
        let client = Fixture.api
        try client.accept(fixtureHealth(target.id, endpoint: base), endpoint: base, authenticated: true)
        let gateway = WindowGateway(persistence: store, client: client)
        var dismissals = 0
        gateway.attachPresenter(UUID()) { if case .close = $0 { dismissals += 1 } }
        await gateway.client.onSessionSnapshot?(HostSessionsResponse(sessions: [session, other]), target)
        gateway.observe(id: window.id, isPresented: true, isFocused: true)
        let requestStart = Fixture.requests.count

        gateway.close(id: window.id)
        precondition(dismissals == 1 && store.windows(hostID: target.id).isEmpty)
        precondition(Fixture.sessions[base.host!]?.count == 2, "Close Window keeps every Mac session")
        precondition(!Fixture.requests.dropFirst(requestStart).contains(where: { $0.hasPrefix("DELETE") }))

        gateway.observe(id: window.id, isPresented: false, isFocused: false)
        try gateway.open(id: window.id)
        gateway.observe(id: window.id, isPresented: true, isFocused: true)
        Fixture.beforeEndSessionReply = { throw URLError(.networkConnectionLost) }
        do { try await gateway.endSession(id: window.id); preconditionFailure("Expected end-session failure") }
        catch {}
        precondition(dismissals == 1 && store.windows(hostID: target.id) == [window],
            "Failed termination must leave the window open for retry")
        precondition(Fixture.sessions[base.host!]?.count == 2)

        try await gateway.endSession(id: window.id)
        precondition(dismissals == 2 && store.windows(hostID: target.id).isEmpty)
        precondition(Fixture.sessions[base.host!]?.map(\.id) == [other.id], "End Session stops only its target")
        let requests = Array(Fixture.requests.dropFirst(requestStart))
        precondition(requests.filter { $0 == "DELETE /api/sessions/\(window.id)" }.count == 2)
        precondition(!requests.contains(where: { $0.hasPrefix("POST /api/workspaces/") }),
            "Closing and reopening must not create replacement processes")
        print("PASS: closing preserves Mac sessions; ending waits for acknowledgement, survives failure, and stops only its target")
    }

    @MainActor
    static func accept(_ target: ConnectedHost, in connection: CompanionClient) throws {
        let hostname = ["host-1": "fixture", "host-2": "other", "names-host": "names"][target.id]!
        let endpoint = URL(string: "http://\(hostname).invalid:7777")!
        try connection.accept(fixtureHealth(target.id, endpoint: endpoint), endpoint: endpoint, authenticated: true)
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
