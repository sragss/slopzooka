import Combine
import SwiftUI

@MainActor
final class LauncherState: ObservableObject {
    let connection = HostConnection()
    @Published var host = ""
    @Published var pairingCode = ""
    @Published var needsPairing = false
    @Published var healthState: HealthState = .idle
    @Published var recentRepos: [RecentRepoSummary] = []
    @Published var recentWorkspaces: [WorkspaceSummary] = []
    @Published var availableOwners: [RepoOwnerSummary] = []
    @Published var frontends: [FrontendSummary] = []
    @Published var frontendWarning: String?
    @Published var repoState: RepoState = .idle
    @Published var workspaceState: WorkspaceState = .idle
    @Published var selectedTool: LaunchTarget = .codex
    @Published var searchText = ""
    @Published var busyRepoID: String?
    @Published var busyWorkspaceID: String?
    @Published var isCreatingRepo = false
    @Published var mutatingWorkspaceID: String?
    @Published var isPruningMissingWorkspaces = false
    @Published var feedback: LaunchFeedback?
    var onTerminalLaunch: ((TerminalWindowPayload) -> Void)?
    var onSessionSnapshot: (([TerminalWindowPayload]) -> Void)?

    private var connecting = false
    private var refreshing = false
    private var pendingHosts: [String] = []
    var normalizedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isMutatingWorkspace: Bool {
        busyRepoID != nil || busyWorkspaceID != nil || mutatingWorkspaceID != nil || isCreatingRepo
            || isPruningMissingWorkspaces
    }
    var filteredRepos: [RecentRepoSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? recentRepos : recentRepos.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(query) }
    }

    func loadSavedPreferences() {
        host = UserDefaults.standard.string(forKey: "companionHost") ?? ""
        selectedTool = LaunchTarget(rawValue: UserDefaults.standard.string(forKey: "selectedTool") ?? "") ?? .codex
    }
    func persistSelectedTool() { UserDefaults.standard.set(selectedTool.rawValue, forKey: "selectedTool") }
    func preferredOwnerLogin() -> String? {
        let saved = UserDefaults.standard.string(forKey: "newRepoOwnerLogin")
        return availableOwners.first(where: { $0.login == saved })?.login ?? availableOwners.first?.login
    }

    func maybeAutoConnect(candidateHost: String, reason: String) async {
        await maybeAutoConnect(candidateHosts: [candidateHost], reason: reason)
    }
    func maybeAutoConnect(candidateHosts: [String], reason: String) async {
        for candidate in candidateHosts where !pendingHosts.contains(candidate) { pendingHosts.append(candidate) }
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        while !pendingHosts.isEmpty {
            let candidate = pendingHosts.removeFirst()
            if connection.endpoint != nil {
                pendingHosts.removeAll()
                return
            }
            host = candidate
            if await connectAndRefresh() {
                pendingHosts.removeAll()
                return
            }
        }
    }

    @discardableResult
    func connectAndRefresh() async -> Bool {
        guard let base = CompanionAPI.baseURL(host: normalizedHost) else {
            healthState = .failure("Enter a valid companion host")
            return false
        }
        healthState = .checking
        do {
            let health = try await CompanionAPI.request(
                CompanionHealthResponse.self, base: base, path: "/health", timeout: 4)
            guard base == CompanionAPI.baseURL(host: normalizedHost) else { return false }
            try connection.accept(health, endpoint: base)
            needsPairing = !health.paired
            healthState = .success(health)
            UserDefaults.standard.set(normalizedHost, forKey: "companionHost")
            if needsPairing {
                recentRepos = []
                recentWorkspaces = []
                availableOwners = []
                frontends = []
                return true
            }
            await refreshHostCatalog()
            await loadWorkspaces(base: base)
            await loadRepositories(base: base)
            await loadOwners(base: base)
            return true
        } catch {
            healthState = .failure(error.localizedDescription)
            return false
        }
    }

    func pair() async {
        guard let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        do {
            try await CompanionAPI.pair(base: base, code: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines))
            pairingCode = ""
            await connectAndRefresh()
        } catch { show(error) }
    }

    func refreshHostCatalog() async {
        guard !refreshing, !needsPairing, let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let sessions = try await CompanionAPI.request(HostSessionsResponse.self, base: base, path: "/api/sessions")
            guard !Task.isCancelled, base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            onSessionSnapshot?(sessions.sessions.compactMap { terminalPayload($0, base: base) })
            // Preview availability must not block terminal recovery.
            let catalog = try await CompanionAPI.request(FrontendCatalog.self, base: base, path: "/api/frontends")
            guard !Task.isCancelled, base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            frontends = catalog.frontends
            frontendWarning = catalog.warning
        } catch {
            guard !Task.isCancelled, base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            frontendWarning = error.localizedDescription
            if (error as? CompanionError)?.statusCode == 401 { needsPairing = true }
        }
    }

    private func loadRepositories(base: URL) async {
        repoState = .loading
        do {
            let result = try await CompanionAPI.request(
                RecentReposResponse.self, base: base, path: "/api/repos/recent?limit=30")
            guard base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            recentRepos = result.repos
            repoState = .loaded(viewerLogin: result.viewerLogin, count: result.repos.count)
        } catch { repoState = .failure(error.localizedDescription) }
    }
    private func loadWorkspaces(base: URL) async {
        workspaceState = .loading
        do {
            let result = try await CompanionAPI.request(
                RecentWorkspacesResponse.self, base: base, path: "/api/workspaces?limit=100")
            guard base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            recentWorkspaces = result.workspaces
            workspaceState = .loaded(count: result.workspaces.count)
        } catch { workspaceState = .failure(error.localizedDescription) }
    }
    private func loadOwners(base: URL) async {
        do {
            let result = try await CompanionAPI.request(AvailableOwnersResponse.self, base: base, path: "/api/owners")
            guard base == CompanionAPI.baseURL(host: normalizedHost) else { return }
            availableOwners = result.owners
        } catch { feedback = LaunchFeedback(message: error.localizedDescription, style: .error) }
    }

    func launch(_ repo: RecentRepoSummary) async {
        guard !isMutatingWorkspace, let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        let profile = selectedTool.queryValue
        busyRepoID = repo.id
        defer { busyRepoID = nil }
        do {
            let body = try JSONEncoder().encode(
                LaunchWorkspaceRequest(nameWithOwner: repo.nameWithOwner, profile: profile))
            let workspace = try await CompanionAPI.request(
                LaunchWorkspaceResponse.self, base: base, path: "/api/workspaces/launch", method: "POST", body: body,
                timeout: 300)
            try await startSession(workspace: workspace, base: base, profile: profile)
            await loadWorkspaces(base: base)
        } catch { show(error) }
    }

    func createRepoAndLaunch(owner: String, repoName: String, isPrivate: Bool) async -> Bool {
        guard !isMutatingWorkspace, let base = CompanionAPI.baseURL(host: normalizedHost) else { return false }
        let profile = selectedTool.queryValue
        isCreatingRepo = true
        defer { isCreatingRepo = false }
        do {
            let body = try JSONEncoder().encode(
                CreateRepoAndLaunchRequest(
                    owner: owner, repoName: repoName, visibility: isPrivate ? "private" : "public", profile: profile))
            let workspace = try await CompanionAPI.request(
                LaunchWorkspaceResponse.self, base: base, path: "/api/repos/create-and-launch", method: "POST",
                body: body, timeout: 300)
            UserDefaults.standard.set(owner, forKey: "newRepoOwnerLogin")
            try await startSession(workspace: workspace, base: base, profile: profile)
            await loadWorkspaces(base: base)
            await loadRepositories(base: base)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func reopen(_ workspace: WorkspaceSummary) async {
        guard !isMutatingWorkspace, let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        let profile = selectedTool.queryValue
        busyWorkspaceID = workspace.id
        defer { busyWorkspaceID = nil }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["profile": profile as Any? ?? NSNull()])
            let result = try await CompanionAPI.request(
                LaunchWorkspaceResponse.self, base: base, path: "/api/workspaces/\(workspace.id)/reopen",
                method: "POST", body: body)
            try await startSession(workspace: result, base: base, profile: profile)
            await loadWorkspaces(base: base)
        } catch { show(error) }
    }

    private func startSession(workspace: LaunchWorkspaceResponse, base: URL, profile: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "sessionId": UUID().uuidString, "profile": profile as Any? ?? NSNull(),
        ])
        let result = try await CompanionAPI.request(
            CreatedSessionResponse.self, base: base,
            path: "/api/workspaces/\(workspace.workspaceId)/sessions", method: "POST", body: body)
        guard let terminal = terminalPayload(result.session, base: base) else { throw URLError(.badURL) }
        onTerminalLaunch?(terminal)
        feedback = LaunchFeedback(message: "\(workspace.repo.nameWithOwner) • \(workspace.branchName)", style: .success)
    }

    private func terminalPayload(_ session: HostSession, base: URL) -> TerminalWindowPayload? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/terminal"
        components.queryItems = [URLQueryItem(name: "sessionId", value: session.id)]
        guard let url = components.url else { return nil }
        return TerminalWindowPayload(
            id: session.id, workspaceId: session.workspaceId, title: "\(session.title) • \(session.cwd)",
            urlString: url.absoluteString)
    }

    func archive(_ workspace: WorkspaceSummary) async {
        guard !isMutatingWorkspace, let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        mutatingWorkspaceID = workspace.id
        defer { mutatingWorkspaceID = nil }
        do {
            _ = try await CompanionAPI.request(
                ArchiveWorkspaceResponse.self, base: base, path: "/api/workspaces/\(workspace.id)/archive",
                method: "POST")
            await loadWorkspaces(base: base)
        } catch { show(error) }
    }
    func pruneMissingWorkspaces() async {
        guard !isMutatingWorkspace, let base = CompanionAPI.baseURL(host: normalizedHost) else { return }
        isPruningMissingWorkspaces = true
        defer { isPruningMissingWorkspaces = false }
        do {
            let result = try await CompanionAPI.request(
                PruneMissingWorkspacesResponse.self, base: base, path: "/api/workspaces/prune-missing", method: "POST")
            feedback = LaunchFeedback(message: "Hidden \(result.archivedCount) missing workspaces", style: .success)
            await loadWorkspaces(base: base)
        } catch { show(error) }
    }
    private func show(_ error: Error) { feedback = LaunchFeedback(message: error.localizedDescription, style: .error) }
}
