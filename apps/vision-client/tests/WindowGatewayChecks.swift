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
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(layouts[key, default: WindowLayout()]))
        }
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
        let terminal = WindowRecord(id: "terminal-1", kind: .terminal, targetID: "terminal-1")
        let preview = WindowRecord(id: "host-1:web", kind: .preview, targetID: "web")
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
        gateway.attachPresenter(presenterID) { _, id, opening in
            if let id { if opening { opened.append(id) } else { dismissed.append(id) } }
        }
        let session = HostSession(id: terminal.id, workspaceId: "workspace", profile: nil,
            title: "Shell", cwd: "/project", status: "running")
        let closedSession = HostSession(id: "closed-session", workspaceId: "workspace", profile: nil,
            title: "Detached", cwd: "/project", status: "running")
        await gateway.launcher.onSessionSnapshot?([session, closedSession], base, hostID)
        await until { gateway.previewPayload(for: preview.id) != nil }
        precondition(opened == [preview.id], "An OS-restored scene is reused; only missing windows are opened")
        precondition(gateway.terminalPayload(for: terminal.id) != nil)
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
        await gateway.launcher.onSessionSnapshot?([session], base, hostID)
        precondition(CompanionAPI.layouts[base.host!]!.windows.count == 2, "Background and disconnect never close saved windows")
        precondition(opened.count == 1)
        gateway.close(WindowReference(hostID: hostID, window: preview), dismiss: false)
        await until { CompanionAPI.layouts[base.host!]!.windows.count == 1 }
        precondition(dismissed.isEmpty, "System discard must not recursively request another dismissal")

        // Restored scenes may be discarded before connection/bootstrap completes.
        let next = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        next.close(reference, dismiss: false)
        next.attachPresenter(UUID()) { _, id, opening in if opening, let id { opened.append(id) } }
        await next.launcher.onSessionSnapshot?([session], base, hostID)
        await until { CompanionAPI.layouts[base.host!]!.windows.isEmpty }
        precondition(opened == [preview.id], "A cold-start discard must win over the remote snapshot")
        precondition(!CompanionAPI.requests.contains(where: { $0.contains("/sessions") }), "Recovery never spawns replacement processes")
        print("PASS: independent scene recovery, deduplicated presentation, and explicit closure")

        CompanionAPI.layouts[base.host!] = WindowLayout(windows: [terminal])
        let missing = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        var missingOpens = 0
        missing.attachPresenter(UUID()) { _, _, opening in if opening { missingOpens += 1 } }
        await missing.launcher.onSessionSnapshot?([], base, hostID)
        await missing.launcher.onSessionSnapshot?([], base, hostID)
        precondition(missingOpens == 1 && missing.terminalPayload(for: terminal.id) == nil)
        precondition(missing.message(for: terminal.id).contains("no longer available"))
        let background = WindowGateway(persistence: WindowPersistence(defaults: defaults))
        background.observe(id: terminal.id, isPresented: false, isFocused: false)
        background.attachPresenter(UUID()) { _, _, opening in if opening { missingOpens += 1 } }
        await background.launcher.onSessionSnapshot?([session], base, hostID)
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
        let refresh = Task { await latePreview.launcher.onSessionSnapshot?([], base, hostID) }
        await until { releasePreview != nil }
        latePreview.close(WindowReference(hostID: hostID, window: preview), dismiss: false)
        await until { CompanionAPI.layouts[base.host!]!.windows.isEmpty }
        releasePreview!.resume()
        await refresh.value
        await until { finishedPreview }
        precondition(latePreview.previewPayload(for: preview.id) == nil)
        await latePreview.launcher.onSessionSnapshot?([], base, hostID)
        precondition(CompanionAPI.layouts[base.host!]!.windows.isEmpty)
        let encoded = try JSONEncoder().encode(CompanionAPI.layouts[base.host!]!)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("transient-secret"))
        print("PASS: late preview resolution cannot resurrect a closed window")
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
