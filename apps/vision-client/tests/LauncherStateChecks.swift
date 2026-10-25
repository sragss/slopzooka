import Foundation

// Compile with the production LauncherState, HostConnection and CompanionModels.
// This transport deliberately returns after cancellation to exercise stale completions.
@MainActor
enum CompanionAPI {
    static var pending: [CheckedContinuation<Void, Never>] = []
    static var sessionRequests = 0
    static var pairRequests = 0
    static var pendingPair: CheckedContinuation<Void, Never>?
    static func baseURL(host: String) -> URL? { URL(string: "http://fixture.invalid") }
    static func request<T: Decodable>(_ type: T.Type, base: URL, path: String,
        method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20) async throws -> T {
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
        let terminal = URL(string: "http://Mac:7777/terminal?sessionId=fixture")!
        precondition(TerminalNavigation.allows(URL(string: "http://mac:7777/terminal?sessionId=fixture")!, document: terminal))
        precondition(TerminalNavigation.allows(URL(string: "http://mac/terminal")!, document: URL(string: "http://Mac:80/terminal")!))
        for rejected in ["http://other:7777/terminal", "https://mac:7777/terminal", "http://mac:7778/terminal", "http://mac:7777/dashboard", "http://user:pass@mac:7777/terminal"] {
            precondition(!TerminalNavigation.allows(URL(string: rejected)!, document: terminal))
        }
        let state = LauncherState()
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

        state.needsPairing = true
        state.pairingCode = "123456"
        let pairing = Task { await state.pair() }
        while CompanionAPI.pendingPair == nil { await Task.yield() }
        await state.pair()
        precondition(CompanionAPI.pairRequests == 1, "Auto-submit must not send duplicate requests")
        CompanionAPI.pendingPair?.resume()
        await pairing.value
        precondition(!state.isPairing && state.pairingCode.isEmpty)
        precondition(state.pairingError == "Wrong code")
        print("PASS: cancellation unlocks controls, stale completions cannot launch or reset newer work, errors remain visible, pairing submits once")
    }
}
