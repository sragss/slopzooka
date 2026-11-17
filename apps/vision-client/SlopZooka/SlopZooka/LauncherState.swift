import Combine
import SwiftUI

@MainActor
final class LauncherState: ObservableObject {
    let client: CompanionClient

    init(client: CompanionClient) {
        self.client = client
        selectedTool = LaunchTarget(rawValue: UserDefaults.standard.string(forKey: "selectedTool") ?? "") ?? .codex
        client.onConnected = { [weak self] target in
            guard let self else { return }
            self.catalogTask?.cancel()
            self.availableOwners = []
            self.repoState = .idle
            self.workspaceState = .idle
            self.codexState = .idle
            self.feedback = nil
            guard !self.client.needsPairing else { return }
            self.catalogTask = Task { [weak self] in
                guard let self else { return }
                async let workspaces: Void = self.loadWorkspaces(hostID: target.id)
                async let repositories: Void = self.loadRepositories(hostID: target.id)
                async let owners: Void = self.loadOwners(hostID: target.id)
                async let codex: Void = self.loadCodexThreads(hostID: target.id)
                _ = await (workspaces, repositories, owners, codex)
            }
        }
    }
    deinit { catalogTask?.cancel() }
    private var catalogTask: Task<Void, Never>?
    var recentRepos: [RecentRepoSummary] { repoState.value?.repos ?? [] }
    var recentWorkspaces: [WorkspaceSummary] { workspaceState.value?.workspaces ?? [] }
    @Published private(set) var availableOwners: [RepoOwnerSummary] = []
    @Published private(set) var repoState: CatalogState<RecentReposResponse> = .idle
    @Published private(set) var workspaceState: CatalogState<RecentWorkspacesResponse> = .idle
    @Published private(set) var codexState: CatalogState<CodexThreadsResponse> = .idle
    @Published var selectedTool: LaunchTarget = .codex
    @Published var searchText = ""
    @Published var repoCreationError: String?
    private enum Operation: Equatable {
        case launchRepo(String)
        case reopenWorkspace(String)
        case resumeThread(String)
        case createRepo(UUID)
        case archiveWorkspace
        case pruneWorkspaces
    }
    @Published private var operation: Operation?
    var busyRepoID: String? { if case .launchRepo(let id) = operation { return id }; return nil }
    var busyWorkspaceID: String? { if case .reopenWorkspace(let id) = operation { return id }; return nil }
    var busyThreadID: String? { if case .resumeThread(let id) = operation { return id }; return nil }
    var isCreatingRepo: Bool { if case .createRepo = operation { return true }; return false }
    var isPruningMissingWorkspaces: Bool { operation == .pruneWorkspaces }
    @Published var feedback: LaunchFeedback?
    var launchTerminal: ((String, String, String?) async throws -> Void)?
    var resumeThread: ((String, String) async throws -> Void)?
    var isMutatingWorkspace: Bool { operation != nil }
    var filteredRepos: [RecentRepoSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            ? recentRepos : recentRepos.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(query) }
    }
    var filteredCodexThreads: [CodexThreadSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array((codexState.value?.threads ?? []).prefix(25)).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    func loadCodexThreads(hostID: String) async {
        await load(\.codexState, hostID: hostID, fetch: client.codexThreads)
    }

    func resume(_ thread: CodexThreadSummary) async {
        guard operation == nil, thread.available, let target = client.current else { return }
        let nextOperation = Operation.resumeThread(thread.id)
        operation = nextOperation
        defer { if operation == nextOperation { operation = nil } }
        do {
            guard let resumeThread else { throw CompanionError(message: "Window gateway is unavailable") }
            try await resumeThread(thread.id, target.id)
        } catch {
            guard !Task.isCancelled, client.current == target else { return }
            feedback = LaunchFeedback(message: error.localizedDescription, style: .error)
        }
    }

    func persistSelectedTool() { UserDefaults.standard.set(selectedTool.rawValue, forKey: "selectedTool") }
    func preferredOwnerLogin() -> String? {
        let saved = UserDefaults.standard.string(forKey: "newRepoOwnerLogin")
        return availableOwners.first(where: { $0.login == saved })?.login ?? availableOwners.first?.login
    }

    private func loadRepositories(hostID: String) async {
        await load(\.repoState, hostID: hostID, fetch: client.repositories)
    }
    func loadWorkspaces(hostID: String) async {
        await load(\.workspaceState, hostID: hostID, fetch: client.workspaces)
    }
    private func load<Value>(
        _ state: ReferenceWritableKeyPath<LauncherState, CatalogState<Value>>,
        hostID: String, fetch: @MainActor (String) async throws -> Value
    ) async {
        guard !Task.isCancelled, let target = client.current, target.id == hostID else { return }
        let requestID = UUID()
        self[keyPath: state] = .loading(requestID)
        do {
            let result = try await fetch(hostID)
            guard !Task.isCancelled, target == client.current, self[keyPath: state].requestID == requestID else { return }
            self[keyPath: state] = .loaded(result)
        } catch {
            guard !Task.isCancelled, target == client.current, self[keyPath: state].requestID == requestID else { return }
            self[keyPath: state] = .failure(error.localizedDescription)
        }
    }
    private func loadOwners(hostID: String) async {
        guard !Task.isCancelled, let target = client.current, target.id == hostID else { return }
        do {
            let result = try await client.owners(hostID: hostID)
            guard !Task.isCancelled, target == client.current else { return }
            availableOwners = result.owners
        } catch {
            guard !Task.isCancelled, target == client.current else { return }
            feedback = LaunchFeedback(message: error.localizedDescription, style: .error)
        }
    }

    func launch(_ repo: RecentRepoSummary) async {
        let profile = selectedTool.queryValue
        await mutateWorkspace(.launchRepo(repo.id)) { hostID in
            let workspace = try await client.launchWorkspace(hostID: hostID, nameWithOwner: repo.nameWithOwner, profile: profile)
            try await startSession(workspace: workspace, hostID: hostID, profile: profile)
        }
    }

    func createRepoAndLaunch(owner: String, repoName: String, isPrivate: Bool) async -> Bool {
        guard !isMutatingWorkspace, let hostID = client.current?.id else { return false }
        let profile = selectedTool.queryValue
        let creation = Operation.createRepo(UUID())
        operation = creation
        repoCreationError = nil
        defer {
            if operation == creation { operation = nil }
        }
        do {
            let workspace = try await client.createRepository(hostID: hostID, owner: owner, name: repoName, isPrivate: isPrivate, profile: profile)
            try Task.checkCancellation()
            guard operation == creation else { return false }
            UserDefaults.standard.set(owner, forKey: "newRepoOwnerLogin")
            try await startSession(workspace: workspace, hostID: hostID, profile: profile)
            await loadWorkspaces(hostID: hostID)
            await loadRepositories(hostID: hostID)
            return true
        } catch {
            if !Task.isCancelled && operation == creation { repoCreationError = error.localizedDescription }
            return false
        }
    }

    func cancelRepoCreation() {
        guard isCreatingRepo else { return }
        operation = nil
        feedback = LaunchFeedback(message: "Stopped waiting. The repository may still finish creating on your Mac; check your projects before trying again.", style: .neutral)
    }

    func reopen(_ workspace: WorkspaceSummary) async {
        let profile = selectedTool.queryValue
        await mutateWorkspace(.reopenWorkspace(workspace.id)) { hostID in
            let result = try await client.reopenWorkspace(hostID: hostID, id: workspace.id, profile: profile)
            try await startSession(workspace: result, hostID: hostID, profile: profile)
        }
    }

    private func startSession(workspace: LaunchWorkspaceResponse, hostID: String, profile: String?) async throws {
        try Task.checkCancellation()
        guard let launchTerminal else { throw CompanionError(message: "Window gateway is unavailable") }
        try await launchTerminal(workspace.workspaceId, hostID, profile)
        feedback = LaunchFeedback(message: "\(workspace.repo.nameWithOwner) • \(workspace.branchName)", style: .success)
    }

    func archive(_ workspace: WorkspaceSummary) async {
        await mutateWorkspace(.archiveWorkspace) { hostID in
            try await client.archiveWorkspace(hostID: hostID, id: workspace.id)
        }
    }
    func pruneMissingWorkspaces() async {
        await mutateWorkspace(.pruneWorkspaces) { hostID in
            let result = try await client.pruneMissingWorkspaces(hostID: hostID)
            feedback = LaunchFeedback(message: "Hidden \(result.archivedCount) missing workspaces", style: .success)
        }
    }

    private func mutateWorkspace(_ nextOperation: Operation, action: @MainActor (String) async throws -> Void) async {
        guard operation == nil, let hostID = client.current?.id else { return }
        operation = nextOperation
        defer { operation = nil }
        do {
            try await action(hostID)
            await loadWorkspaces(hostID: hostID)
        } catch { feedback = LaunchFeedback(message: error.localizedDescription, style: .error) }
    }
}
