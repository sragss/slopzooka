import Foundation

// Compile with the production client, launcher, and models.
// This transport deliberately returns after cancellation to exercise stale completions.
@MainActor
enum Fixture {
    static var pending: [CheckedContinuation<Void, Never>] = []
    static var sessionRequests = 0
    static var pairRequests = 0
    static var pendingPair: CheckedContinuation<Void, Never>?
    static var healthRequests: [URL] = []
    static var healthReply: ((URL) async throws -> CompanionHealthResponse)?
    static var api: CompanionClient { CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials(), exchange: exchange) }
    static func exchange(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let base = origin(request.url!)
        let path = request.url!.path
        if path == "/api/pair" {
            pairRequests += 1
            await withCheckedContinuation { pendingPair = $0 }
            throw CompanionError(message: "Wrong code")
        }
        if path == "/health", let reply = healthReply {
            healthRequests.append(base)
            let health = try await reply(base)
            return try json(["hostId": health.hostId, "paired": health.paired,
                "protocolVersion": health.protocolVersion, "controlOrigin": health.controlOrigin,
                "logFilePath": health.logFilePath], for: request)
        }
        if path == "/api/repos/create-and-launch" {
            await withCheckedContinuation { pending.append($0) }
            return try json(["localCheckoutPath": "/fixture", "worktreePath": "/fixture", "branchName": "test",
                "baseRef": "main", "wasCloned": false, "workspaceId": "fixture",
                "repo": ["name": "fixture", "nameWithOwner": "test/fixture", "url": "", "sshUrl": "",
                    "pushedAt": "2026-01-01T00:00:00Z", "isPrivate": true, "defaultBranch": "main",
                    "owner": ["login": "test", "avatarUrl": ""]]], for: request)
        }
        if path.hasSuffix("/sessions") { sessionRequests += 1 }
        throw CompanionError(message: "fixture failure")
    }
}
@main
struct LauncherStateChecks {
    @MainActor
    static func main() async {
        defer { CompanionTestPreferences.clean() }
        var speech = SpeechEndpoint()
        precondition(!speech.shouldFinish(at: 100), "Silence without words must never send")
        speech.received("hello", at: 100)
        precondition(!speech.shouldFinish(at: 101.4), "Short pauses must not send")
        speech.heardVoice(at: 101.3)
        precondition(!speech.shouldFinish(at: 102), "Continuing speech extends the pause window")
        precondition(speech.shouldFinish(at: 102.8), "A completed phrase should send after a pause")
        speech.received("hello world", at: 103)
        precondition(!speech.shouldFinish(at: 104), "Late recognition results get time to settle")
        speech = SpeechEndpoint()
        precondition(!speech.shouldFinish(at: 200), "A new recording must not inherit old words")
        print("PASS: dictation waits for words and a pause, extends for speech, and resets between recordings")
        var meter = SpeechLevelMeter()
        func measure(_ samples: [Float]) -> [Double] {
            samples.withUnsafeBufferPointer { meter.receive(samples: $0, sampleRate: 48_000) }
        }
        precondition(measure(Array(repeating: 0, count: 960)).allSatisfy { $0 == 0 })
        let quiet = measure(Array(repeating: 0.005, count: 960))
        let loud = measure(Array(repeating: 0.1, count: 960))
        precondition(zip(loud, quiet).allSatisfy { $0 > $1 && $1 > 0 },
            "Every bar must react to current microphone energy in the first callback")
        let onset = Array(repeating: Float(0), count: 3840) + Array(repeating: Float(0.1), count: 960)
        precondition(measure(onset) == loud, "Older silence in a large input buffer must not dilute a new onset")
        let ended = Array(repeating: Float(0.1), count: 3840) + Array(repeating: Float(0), count: 960)
        precondition(measure(ended).allSatisfy { $0 == 0 }, "Old speech must not linger across four later callbacks")
        precondition(measure(Array(repeating: 10, count: 960)).allSatisfy { $0 >= 0 && $0 <= 1 })
        precondition(measure([]).allSatisfy { $0 == 0 })
        print("PASS: all five waveform bars use the newest 20 ms, react to onset immediately, stay bounded, and drop old speech")
        let terminal = URL(string: "http://Mac:7777/terminal?sessionId=fixture")!
        precondition(TerminalNavigation.allows(URL(string: "http://mac:7777/terminal?sessionId=fixture")!, document: terminal))
        precondition(TerminalNavigation.allows(URL(string: "http://mac/terminal")!, document: URL(string: "http://Mac:80/terminal")!))
        for rejected in ["http://other:7777/terminal", "https://mac:7777/terminal", "http://mac:7778/terminal", "http://mac:7777/dashboard", "http://user:pass@mac:7777/terminal"] {
            precondition(!TerminalNavigation.allows(URL(string: rejected)!, document: terminal))
        }
        let state = LauncherState(client: Fixture.api)
        state.launchTerminal = { workspaceID, hostID, _ in
            _ = try await state.client.launchSession(hostID: hostID, workspaceID: workspaceID, sessionID: "fixture-session", profile: nil)
        }
        let fixtureBase = URL(string: "http://fixture.invalid")!
        try! state.client.accept(fixtureHealth("fixture", endpoint: fixtureBase), endpoint: fixtureBase, authenticated: true)
        state.client.host = "fixture.invalid"
        let first = Task { await state.createRepoAndLaunch(owner: "test", repoName: "one", isPrivate: true) }
        while Fixture.pending.count < 1 { await Task.yield() }
        precondition(state.isMutatingWorkspace)
        first.cancel()
        state.cancelRepoCreation()
        precondition(!state.isMutatingWorkspace, "Dismissal must immediately unlock project controls")
        let second = Task { await state.createRepoAndLaunch(owner: "test", repoName: "two", isPrivate: true) }
        while Fixture.pending.count < 2 { await Task.yield() }
        Fixture.pending[0].resume()
        let firstResult = await first.value
        precondition(!firstResult)
        precondition(state.isCreatingRepo, "An old completion must not unlock a newer operation")
        precondition(Fixture.sessionRequests == 0, "Cancellation must not launch a late terminal")
        Fixture.pending[1].resume()
        let secondResult = await second.value
        precondition(!secondResult)
        precondition(!state.isMutatingWorkspace)
        precondition(state.repoCreationError == "fixture failure", "Creation errors must remain visible inside the sheet")

        state.client.host = "fixture.invalid:17777"
        let pairingBase = URL(string: "http://fixture.invalid:17777")!
        try! state.client.accept(fixtureHealth("fixture", endpoint: pairingBase), endpoint: pairingBase, authenticated: false)
        state.client.pairingCode = "123456"
        let pairing = Task { await state.client.pair() }
        while Fixture.pendingPair == nil { await Task.yield() }
        await state.client.pair()
        precondition(Fixture.pairRequests == 1, "Auto-submit must not send duplicate requests")
        Fixture.pendingPair?.resume()
        await pairing.value
        precondition(!state.client.isPairing && state.client.pairingCode.isEmpty)
        precondition(state.client.pairingError == "http://fixture.invalid:17777\nWrong code")
        print("PASS: cancellation unlocks controls, stale completions cannot launch or reset newer work, errors remain visible, pairing submits once")

        // Both startup paths share one queue, even when Bonjour arrives first.
        let saved = "mac.local:7777", discovered = "mac.local:17777"
        let savedPreference = UserDefaults.standard.object(forKey: "companionHost")
        defer { UserDefaults.standard.set(savedPreference, forKey: "companionHost") }
        for savedFails in [false, true] {
            let startup = Fixture.api
            startup.host = saved
            Fixture.healthRequests = []
            var release: CheckedContinuation<Void, Never>?
            Fixture.healthReply = { base in
                if base.port == 7777 {
                    await withCheckedContinuation { release = $0 }
                    if savedFails { throw URLError(.cannotConnectToHost) }
                }
                return health(base: base)
            }
            let attempt = Task { await startup.maybeAutoConnect(candidateHosts: [discovered]) }
            while release == nil { await Task.yield() }
            await startup.maybeAutoConnect(candidateHosts: [startup.normalizedHost])
            await startup.maybeAutoConnect(candidateHosts: [discovered])
            precondition(Fixture.healthRequests.map(\.port) == [7777], "Discovery and retries must not race the saved host")
            release!.resume()
            await attempt.value
            precondition(Fixture.healthRequests.map(\.port) == (savedFails ? [7777, 17777] : [7777]))
            precondition((try? startup.endpoint(for: startup.current!.id).port) == (savedFails ? 17777 : 7777))
            precondition(startup.needsPairing, "An unpaired saved host remains selected instead of falling through to another instance")
        }
        print("PASS: saved-host priority, serialized discovery/retries, and fallback distinguish companions on different ports")

        // A manual selection supersedes discovery or a previous manual request.
        for oldFails in [false, true] {
            let client = Fixture.api
            var release: CheckedContinuation<Void, Never>?
            var connected: [Int] = []
            client.onConnected = { connected.append(try! client.endpoint(for: $0.id).port!) }
            Fixture.healthReply = { base in
                if base.port == 7777 {
                    await withCheckedContinuation { release = $0 }
                    if oldFails { throw URLError(.cannotConnectToHost) }
                }
                return health(base: base)
            }
            let old = Task { await client.select("mac.local:7777") }
            while release == nil { await Task.yield() }
            await client.select("mac.local:17777")
            release!.resume()
            await old.value
            precondition((try? client.endpoint(for: client.current!.id).port) == 17777 && connected == [17777])
            precondition(client.needsPairing && client.host == "mac.local:17777")
            guard case .success = client.healthState else { preconditionFailure("Old reply replaced selection") }
            precondition(client.health?.hostId == "host-17777")
        }
        let client = Fixture.api
        Fixture.healthReply = { base in health(base: base) }
        await client.select("mac.local:7777")
        client.pairingCode = "123456"
        Fixture.pendingPair = nil
        let oldPair = Task { await client.pair() }
        while Fixture.pendingPair == nil { await Task.yield() }
        await client.select("mac.local:17777")
        client.pairingCode = "654321"
        Fixture.pendingPair!.resume()
        await oldPair.value
        precondition(client.pairingError == nil && client.pairingCode == "654321")
        precondition((try? client.endpoint(for: client.current!.id).port) == 17777 && !client.isPairing)
        let accepted = client.current
        do {
            try client.accept(health(base: try! client.endpoint(for: accepted!.id), version: 2), endpoint: try! client.endpoint(for: accepted!.id), authenticated: true)
            preconditionFailure("Incompatible protocol must be rejected")
        } catch { precondition(client.current == accepted) }
        print("PASS: delayed health and pairing replies cannot overwrite a new selection; incompatible hosts cannot replace the accepted host")
        for sharedHostIdentity in [false, true] {
            try! await catalogSwitchChecks(sharedHostIdentity: sharedHostIdentity)
        }
        try! await catalogSwitchChecks(sharedHostIdentity: false, mutateDuringLoad: true)
    }

    @MainActor
    static func catalogSwitchChecks(sharedHostIdentity: Bool, mutateDuringLoad: Bool = false) async throws {
        let first = URL(string: "http://first.invalid")!, second = URL(string: "http://second.invalid")!
        let secondID = sharedHostIdentity ? "first" : "second"
        let credentials = testCredentials()
        try credentials.pair(first, hostID: "first", token: "secret")
        try credentials.pair(second, hostID: secondID, token: "secret")
        var releaseSessions: CheckedContinuation<Void, Never>?
        var releaseWorkspaces: CheckedContinuation<Void, Never>?
        var pruned = false
        var finishedOldLoad = false
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            let id = request.url!.host! == "first.invalid" ? "first" : "second"
            let path = request.url!.path
            let repo: [String: Any] = ["name": id, "nameWithOwner": "test/\(id)", "url": "", "sshUrl": "",
                "pushedAt": "2026-01-01T00:00:00Z", "isPrivate": true, "owner": ["login": "test", "avatarUrl": ""]]
            switch path {
            case "/health": return try json(healthJSON(id == "second" ? secondID : id, endpoint: origin(request.url!)), for: request)
            case "/api/sessions":
                if id == "second" { await withCheckedContinuation { releaseSessions = $0 } }
                return try json(["sessions": []], for: request)
            case "/api/frontends": return try json(["frontends": []], for: request)
            case "/api/workspaces":
                let workspaces: [[String: Any]] = pruned ? [] : [["workspaceId": id, "repo": repo, "localCheckoutPath": "/",
                    "worktreePath": "/", "branchName": "main", "baseRef": "main", "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z", "existsOnDisk": true]]
                if id == "second", releaseWorkspaces == nil {
                    await withCheckedContinuation { releaseWorkspaces = $0 }
                    finishedOldLoad = true
                }
                return try json(["workspaces": workspaces], for: request)
            case "/api/workspaces/prune-missing":
                pruned = true
                return try json(["archivedCount": 1], for: request)
            case "/api/repos/recent": return try json(["viewerLogin": "test", "repos": [repo]], for: request)
            case "/api/owners": return try json(["viewerLogin": "test", "owners": [["login": id, "avatarUrl": "", "kind": "user"]]], for: request)
            default: preconditionFailure("Unexpected request")
            }
        }
        let state = LauncherState(client: client)
        await client.select(first.absoluteString)
        while state.availableOwners.isEmpty || state.recentWorkspaces.isEmpty || state.recentRepos.isEmpty { await Task.yield() }
        precondition(state.recentRepos.first?.id == "test/first" && state.recentWorkspaces.first?.id == "first")
        precondition(state.availableOwners.first?.login == "first")
        let switching = Task { await client.select(second.absoluteString) }
        while releaseSessions == nil { await Task.yield() }
        precondition(client.current?.id == secondID && client.isReady)
        precondition(state.recentRepos.allSatisfy { $0.id == "test/second" }
            && state.recentWorkspaces.allSatisfy { $0.id == "second" }
            && state.availableOwners.allSatisfy { $0.login == "second" },
            "Accepting another Mac must immediately clear the previous Mac's launch choices, even while refresh is stalled")
        releaseSessions!.resume()
        while releaseWorkspaces == nil || state.availableOwners.isEmpty || state.recentRepos.isEmpty { await Task.yield() }
        precondition(state.recentWorkspaces.isEmpty && state.availableOwners.first?.login == "second" && state.recentRepos.first?.id == "test/second",
            "A stalled workspace request must not block repositories or repository owners")
        if mutateDuringLoad {
            await state.pruneMissingWorkspaces()
            precondition(state.recentWorkspaces.isEmpty)
            releaseWorkspaces!.resume()
            while !finishedOldLoad { await Task.yield() }
            precondition(state.recentWorkspaces.isEmpty,
                "An old initial catalog cannot resurrect workspaces hidden by a later mutation")
            guard case .loaded(let catalog) = state.workspaceState, catalog.workspaces.isEmpty else { preconditionFailure("The newer catalog must retain its loaded state") }
            print("PASS: a mutation's catalog refresh supersedes an older in-flight initial load")
            return
        }
        await client.select(first.absoluteString)
        while state.availableOwners.isEmpty || state.recentWorkspaces.isEmpty || state.recentRepos.isEmpty { await Task.yield() }
        releaseWorkspaces!.resume()
        await switching.value
        precondition(state.recentWorkspaces.first?.id == "first" && state.availableOwners.first?.login == "first")
        guard case .loaded = state.workspaceState else { preconditionFailure("A superseded route cannot replace the loaded workspace state with an error") }
        print("PASS: connection changes clear launch choices, catalogs load independently, and superseded results cannot replace the new state")
    }
    static func health(base: URL, version: Int = 1) -> CompanionHealthResponse {
        fixtureHealth("host-\(base.port!)", endpoint: base, paired: false, version: version)
    }

}
