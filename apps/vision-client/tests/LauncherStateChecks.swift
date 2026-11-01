import Foundation

// Compile with the production LauncherState, HostConnection and CompanionModels.
// This transport deliberately returns after cancellation to exercise stale completions.
@MainActor
enum CompanionAPI {
    static var pending: [CheckedContinuation<Void, Never>] = []
    static var sessionRequests = 0
    static var pairRequests = 0
    static var pendingPair: CheckedContinuation<Void, Never>?
    static var healthRequests: [URL] = []
    static var healthReply: ((URL) async throws -> CompanionHealthResponse)?
    static func baseURL(host: String) -> URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: host.contains("://") ? host : "http://\(host)")
    }
    static func request<T: Decodable>(_ type: T.Type, base: URL, path: String,
        method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) async throws -> T {
        if path == "/health", let reply = healthReply {
            healthRequests.append(base)
            return try await reply(base) as! T
        }
        if path == "/api/repos/create-and-launch" {
            await withCheckedContinuation { pending.append($0) }
            let repo = RecentRepoSummary(name: "fixture", nameWithOwner: "test/fixture", url: "", sshUrl: "",
                pushedAt: Date(), isPrivate: true, defaultBranch: "main",
                owner: .init(login: "test", name: nil, avatarUrl: ""))
            return LaunchWorkspaceResponse(localCheckoutPath: "/fixture", worktreePath: "/fixture",
                branchName: "test", baseRef: "main", wasCloned: false, workspaceId: "fixture", repo: repo) as! T
        }
        if path.hasSuffix("/sessions") { sessionRequests += 1 }
        throw CompanionError(message: "fixture failure")
    }
    static func pair(base: URL, code: String) async throws {
        pairRequests += 1
        await withCheckedContinuation { pendingPair = $0 }
        throw CompanionError(message: "Wrong code")
    }
}
@main
struct LauncherStateChecks {
    @MainActor
    static func main() async {
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
        var quietMeter = SpeechLevelMeter(), loudMeter = SpeechLevelMeter()
        precondition(quietMeter.receive(rms: 0).allSatisfy { $0 == 0 })
        let quiet = quietMeter.receive(rms: 0.005).last!
        let loud = loudMeter.receive(rms: 0.1).last!
        precondition(loud > quiet && quiet > 0, "Waveform amplitude must follow microphone energy")
        for _ in 0..<30 { _ = loudMeter.receive(rms: 0) }
        precondition(loudMeter.levels.allSatisfy { $0 == 0 }, "Silence must settle, without a decorative animation")
        precondition(loudMeter.receive(rms: 10).allSatisfy { $0 >= 0 && $0 <= 1 })
        print("PASS: microphone metering responds to volume, stays bounded, and settles during silence")
        let terminal = URL(string: "http://Mac:7777/terminal?sessionId=fixture")!
        precondition(TerminalNavigation.allows(URL(string: "http://mac:7777/terminal?sessionId=fixture")!, document: terminal))
        precondition(TerminalNavigation.allows(URL(string: "http://mac/terminal")!, document: URL(string: "http://Mac:80/terminal")!))
        for rejected in ["http://other:7777/terminal", "https://mac:7777/terminal", "http://mac:7778/terminal", "http://mac:7777/dashboard", "http://user:pass@mac:7777/terminal"] {
            precondition(!TerminalNavigation.allows(URL(string: rejected)!, document: terminal))
        }
        let state = LauncherState()
        state.launchTerminal = { workspaceID, base, _ in
            _ = try await CompanionAPI.request(CreatedSessionResponse.self, base: base,
                path: "/api/workspaces/\(workspaceID)/sessions", method: "POST")
        }
        state.host = "fixture.invalid"
        let first = Task { await state.createRepoAndLaunch(owner: "test", repoName: "one", isPrivate: true) }
        while CompanionAPI.pending.count < 1 { await Task.yield() }
        precondition(state.isMutatingWorkspace)
        first.cancel()
        state.cancelRepoCreation()
        precondition(!state.isMutatingWorkspace, "Dismissal must immediately unlock project controls")
        let second = Task { await state.createRepoAndLaunch(owner: "test", repoName: "two", isPrivate: true) }
        while CompanionAPI.pending.count < 2 { await Task.yield() }
        CompanionAPI.pending[0].resume()
        let firstResult = await first.value
        precondition(!firstResult)
        precondition(state.isCreatingRepo, "An old completion must not unlock a newer operation")
        precondition(CompanionAPI.sessionRequests == 0, "Cancellation must not launch a late terminal")
        CompanionAPI.pending[1].resume()
        let secondResult = await second.value
        precondition(!secondResult)
        precondition(!state.isMutatingWorkspace)
        precondition(state.repoCreationError == "fixture failure", "Creation errors must remain visible inside the sheet")

        state.host = "fixture.invalid:17777"
        state.needsPairing = true
        state.pairingCode = "123456"
        let pairing = Task { await state.pair() }
        while CompanionAPI.pendingPair == nil { await Task.yield() }
        await state.pair()
        precondition(CompanionAPI.pairRequests == 1, "Auto-submit must not send duplicate requests")
        CompanionAPI.pendingPair?.resume()
        await pairing.value
        precondition(!state.isPairing && state.pairingCode.isEmpty)
        precondition(state.pairingError == "http://fixture.invalid:17777\nWrong code")
        print("PASS: cancellation unlocks controls, stale completions cannot launch or reset newer work, errors remain visible, pairing submits once")

        // Both startup paths share one queue, even when Bonjour arrives first.
        let saved = "mac.local:7777", discovered = "mac.local:17777"
        let savedPreference = UserDefaults.standard.object(forKey: "companionHost")
        defer { UserDefaults.standard.set(savedPreference, forKey: "companionHost") }
        for savedFails in [false, true] {
            let startup = LauncherState()
            startup.host = saved
            CompanionAPI.healthRequests = []
            var release: CheckedContinuation<Void, Never>?
            CompanionAPI.healthReply = { base in
                if base.port == 7777 {
                    await withCheckedContinuation { release = $0 }
                    if savedFails { throw URLError(.cannotConnectToHost) }
                }
                return CompanionHealthResponse(ok: true, hostId: "host-\(base.port!)", paired: false,
                    protocolVersion: 1, name: "fixture", version: "1", hostname: "mac", localHostName: "mac",
                    controlOrigin: base.absoluteString, bonjourServiceType: nil, cwd: "/fixture", logFilePath: "", workspacePaths: nil)
            }
            let attempt = Task { await startup.maybeAutoConnect(candidateHosts: [discovered]) }
            while release == nil { await Task.yield() }
            await startup.maybeAutoConnect(candidateHosts: [startup.normalizedHost])
            await startup.maybeAutoConnect(candidateHosts: [discovered])
            precondition(CompanionAPI.healthRequests.map(\.port) == [7777], "Discovery and retries must not race the saved host")
            release!.resume()
            await attempt.value
            precondition(CompanionAPI.healthRequests.map(\.port) == (savedFails ? [7777, 17777] : [7777]))
            precondition(startup.connection.current?.endpoint.port == (savedFails ? 17777 : 7777))
            precondition(startup.needsPairing, "An unpaired saved host remains selected instead of falling through to another instance")
        }
        print("PASS: saved-host priority, serialized discovery/retries, and fallback distinguish companions on different ports")
    }
}
