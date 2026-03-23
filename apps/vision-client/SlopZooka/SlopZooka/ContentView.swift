import SwiftUI
import Combine

@MainActor
final class LauncherState: ObservableObject {
    @Published var host = ""
    @Published var healthState: HealthState = .idle
    @Published var recentRepos: [RecentRepoSummary] = []
    @Published var recentWorkspaces: [WorkspaceSummary] = []
    @Published var repoState: RepoState = .idle
    @Published var workspaceState: WorkspaceState = .idle
    @Published var selectedTool: LaunchTarget = .codex
    @Published var searchText = ""
    @Published var busyRepoID: String?
    @Published var busyWorkspaceID: String?
    @Published var launchMessage: String?
    @Published var activeTerminalPayload: TerminalWindowPayload?
    @Published var terminalLoadState: TerminalLoadState = .idle

    private let userDefaults = UserDefaults.standard

    var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredRepos: [RecentRepoSummary] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return recentRepos
        }

        return recentRepos.filter { repo in
            repo.nameWithOwner.localizedCaseInsensitiveContains(trimmedQuery) ||
            repo.owner.login.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func loadSavedHost() {
        if let savedHost = userDefaults.string(forKey: "companionHost"), !savedHost.isEmpty {
            host = savedHost
            slzLog("loaded saved host \(savedHost)")
        } else {
            slzLog("no saved host found")
        }
    }

    func connectAndRefresh() async {
        slzLog("connectAndRefresh start host=\(normalizedHost)")
        let didConnect = await runHealthCheck()
        guard didConnect else {
            repoState = .idle
            workspaceState = .idle
            recentRepos = []
            recentWorkspaces = []
            slzLog("connectAndRefresh failed")
            return
        }

        async let reposTask: Void = loadRecentRepos()
        async let workspacesTask: Void = loadWorkspaces()
        _ = await (reposTask, workspacesTask)
    }

    func runHealthCheck() async -> Bool {
        guard !normalizedHost.isEmpty else {
            healthState = .failure("Enter a host first.")
            slzLog("health check blocked: empty host")
            return false
        }

        guard let url = companionURL(path: "/health") else {
            healthState = .failure("Invalid host.")
            slzLog("health check blocked: invalid host \(normalizedHost)")
            return false
        }

        healthState = .checking
        slzLog("health check start \(url.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                healthState = .failure("No HTTP response.")
                slzLog("health check failed: no HTTP response")
                return false
            }

            guard httpResponse.statusCode == 200 else {
                healthState = .failure("Health check failed with status \(httpResponse.statusCode).")
                slzLog("health check failed status=\(httpResponse.statusCode)")
                return false
            }

            let payload = try JSONDecoder().decode(CompanionHealthResponse.self, from: data)
            userDefaults.set(normalizedHost, forKey: "companionHost")
            healthState = .success(payload)
            slzLog("health check success controlOrigin=\(payload.controlOrigin)")
            return true
        } catch {
            healthState = .failure(error.localizedDescription)
            slzLog("health check error \(error.localizedDescription)")
            return false
        }
    }

    func loadRecentRepos() async {
        guard !normalizedHost.isEmpty else {
            repoState = .failure("Enter a companion host first.")
            slzLog("loadRecentRepos blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/repos/recent", queryItems: [URLQueryItem(name: "limit", value: "40")]) else {
            repoState = .failure("Invalid host.")
            slzLog("loadRecentRepos blocked: invalid host \(normalizedHost)")
            return
        }

        repoState = .loading
        slzLog("loadRecentRepos start \(url.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                repoState = .failure("No HTTP response.")
                slzLog("loadRecentRepos failed: no HTTP response")
                return
            }

            guard httpResponse.statusCode == 200 else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                repoState = .failure(message)
                slzLog("loadRecentRepos failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(RecentReposResponse.self, from: data)
            userDefaults.set(normalizedHost, forKey: "companionHost")
            recentRepos = payload.repos
            repoState = .loaded(viewerLogin: payload.viewerLogin, count: payload.repos.count)
            slzLog("loadRecentRepos success count=\(payload.repos.count)")
        } catch {
            repoState = .failure(error.localizedDescription)
            slzLog("loadRecentRepos error \(error.localizedDescription)")
        }
    }

    func loadWorkspaces() async {
        guard !normalizedHost.isEmpty else {
            workspaceState = .failure("Enter a companion host first.")
            slzLog("loadWorkspaces blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/workspaces", queryItems: [URLQueryItem(name: "limit", value: "16")]) else {
            workspaceState = .failure("Invalid host.")
            slzLog("loadWorkspaces blocked: invalid host \(normalizedHost)")
            return
        }

        workspaceState = .loading
        slzLog("loadWorkspaces start \(url.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                workspaceState = .failure("No HTTP response.")
                slzLog("loadWorkspaces failed: no HTTP response")
                return
            }

            guard httpResponse.statusCode == 200 else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                workspaceState = .failure(message)
                slzLog("loadWorkspaces failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(RecentWorkspacesResponse.self, from: data)
            recentWorkspaces = payload.workspaces
            workspaceState = .loaded(count: payload.workspaces.count)
            slzLog("loadWorkspaces success count=\(payload.workspaces.count)")
        } catch {
            workspaceState = .failure(error.localizedDescription)
            slzLog("loadWorkspaces error \(error.localizedDescription)")
        }
    }

    func launch(_ repo: RecentRepoSummary) async {
        guard !normalizedHost.isEmpty else {
            healthState = .failure("Enter a companion host first.")
            slzLog("launch blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/workspaces/launch") else {
            healthState = .failure("Invalid host.")
            slzLog("launch blocked: invalid host \(normalizedHost)")
            return
        }

        busyRepoID = repo.id
        launchMessage = nil
        slzLog("launch start repo=\(repo.nameWithOwner) tool=\(selectedTool.rawValue)")

        defer {
            busyRepoID = nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LaunchWorkspaceRequest(
                    nameWithOwner: repo.nameWithOwner,
                    profile: selectedTool.queryValue
                )
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                launchMessage = "Workspace launch failed: no HTTP response."
                slzLog("launch failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                launchMessage = message
                slzLog("launch failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(LaunchWorkspaceResponse.self, from: data)
            applyLaunchPayload(payload)
            await loadWorkspaces()
        } catch {
            launchMessage = error.localizedDescription
            slzLog("launch error \(error.localizedDescription)")
        }
    }

    func reopen(_ workspace: WorkspaceSummary) async {
        guard !normalizedHost.isEmpty else {
            healthState = .failure("Enter a companion host first.")
            slzLog("reopen blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/workspaces/\(workspace.id)/reopen") else {
            healthState = .failure("Invalid host.")
            slzLog("reopen blocked: invalid host \(normalizedHost)")
            return
        }

        busyWorkspaceID = workspace.id
        launchMessage = nil
        slzLog("reopen start workspace=\(workspace.id) repo=\(workspace.repo.nameWithOwner) tool=\(selectedTool.rawValue)")

        defer {
            busyWorkspaceID = nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                ReopenWorkspaceRequest(profile: selectedTool.queryValue)
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                launchMessage = "Workspace reopen failed: no HTTP response."
                slzLog("reopen failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                launchMessage = message
                slzLog("reopen failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(LaunchWorkspaceResponse.self, from: data)
            applyLaunchPayload(payload)
            await loadWorkspaces()
        } catch {
            launchMessage = error.localizedDescription
            slzLog("reopen error \(error.localizedDescription)")
        }
    }

    func openDemoSession() {
        let urlString: String
        if let demoURL = companionURL(path: "/terminal", queryItems: [
            URLQueryItem(name: "profile", value: selectedTool.queryValue ?? "shell")
        ])?.absoluteString {
            urlString = demoURL
        } else {
            urlString = "https://example.com"
        }

        terminalLoadState = .loading(urlString)
        launchMessage = "Opening demo session."
        activeTerminalPayload = TerminalWindowPayload(
            id: UUID().uuidString,
            title: "Demo Session",
            urlString: urlString
        )
        slzLog("openDemoSession \(urlString)")
    }

    func closeTerminal() {
        slzLog("closeTerminal")
        terminalLoadState = .idle
        activeTerminalPayload = nil
    }

    private func applyLaunchPayload(_ payload: LaunchWorkspaceResponse) {
        slzLog("launch response repo=\(payload.repo.nameWithOwner) branch=\(payload.branchName) url=\(payload.launchURL)")

        guard let terminalURL = URL(string: payload.launchURL) else {
            launchMessage = "Workspace launched, but terminal URL was invalid."
            slzLog("launch failed: invalid terminal URL \(payload.launchURL)")
            return
        }

        terminalLoadState = .loading(terminalURL.absoluteString)
        launchMessage = "\(payload.repo.nameWithOwner) • \(payload.baseRef) → \(payload.branchName)"
        activeTerminalPayload = TerminalWindowPayload(
            id: payload.clusterId,
            title: "\(selectedTool.title) • \(payload.repo.nameWithOwner)",
            urlString: terminalURL.absoluteString
        )
        slzLog("active terminal assigned \(activeTerminalPayload?.id ?? "nil")")
    }

    private func companionURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard !normalizedHost.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "http"
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        if let (host, port) = splitHostAndPort(normalizedHost) {
            components.host = host
            components.port = port
        } else {
            components.host = normalizedHost
        }

        return components.url
    }

    private func splitHostAndPort(_ value: String) -> (String, Int)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return nil
        }

        return (String(parts[0]), port)
    }

    private func decodeAPIError(data: Data, statusCode: Int) -> String {
        if let payload = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return payload.error
        }

        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body, !body.isEmpty {
            return "Request failed (\(statusCode)): \(body)"
        }

        return "Request failed with status \(statusCode)."
    }
}

struct ContentView: View {
    private let debugBuildStamp = "terminal-inline-v5 2026-03-22 22:45"
    private let launcherWindowSize = CGSize(width: 620, height: 820)
    private let terminalWindowSize = CGSize(width: 1280, height: 832)

    @StateObject private var state = LauncherState()
    @StateObject private var debugLog = AppDebugLog.shared
    @State private var isTerminalUtilitiesExpanded = false

    var body: some View {
        Group {
            if let activeTerminalPayload = state.activeTerminalPayload {
                terminalMode(payload: activeTerminalPayload)
            } else {
                ScrollView {
                    launcherMode
                }
            }
        }
        .frame(
            width: state.activeTerminalPayload == nil ? launcherWindowSize.width : terminalWindowSize.width,
            height: state.activeTerminalPayload == nil ? launcherWindowSize.height : terminalWindowSize.height
        )
        .padding(24)
        .task {
            state.loadSavedHost()
            slzLog("ContentView task completed")
        }
        .onAppear {
            slzLog("ContentView appeared")
        }
        .onChange(of: state.activeTerminalPayload?.id) { _, newValue in
            slzLog("active terminal payload changed \(newValue ?? "nil")")
        }
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SlopZooka")
                    .font(.extraLargeTitle)
                    .fontWeight(.semibold)

                Text("Pick a tool, select a recent GitHub repo, and open a fresh worktree on your nearby Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text("Debug Build: \(debugBuildStamp)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("Session State: \(state.activeTerminalPayload == nil ? "none" : "active")")
                    .font(.caption)
                    .foregroundStyle(state.activeTerminalPayload == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Companion Host")
                    .font(.headline)

                TextField("MacName.local:7777", text: $state.host)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                HStack(spacing: 12) {
                    Button("Connect") {
                        Task {
                            await state.connectAndRefresh()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh Repos") {
                        Task {
                            await state.connectAndRefresh()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.normalizedHost.isEmpty)

                    Button("Debug Open Demo Session") {
                        state.openDemoSession()
                    }
                    .buttonStyle(.bordered)
                }

                HealthStatusView(state: state.healthState)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Tool")
                    .font(.headline)

                Picker("Tool", selection: $state.selectedTool) {
                    ForEach(LaunchTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                Text(state.selectedTool.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Workspaces")
                        .font(.headline)

                    Spacer()

                    if case let .loaded(count) = state.workspaceState {
                        Text("\(count) saved")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                workspaceContent
            }
            .padding(20)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Repositories")
                        .font(.headline)

                    Spacer()

                    if case let .loaded(viewerLogin, count) = state.repoState {
                        Text("\(count) from \(viewerLogin)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Search owner or repo", text: $state.searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                repoContent
            }
            .padding(20)
            .frame(minHeight: 520)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            Text("Selecting a repo ensures a checkout and fresh worktree, then opens \(state.selectedTool.title).")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let launchMessage = state.launchMessage {
                Text(launchMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func terminalMode(payload: TerminalWindowPayload) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Active Session")
                    .font(.headline)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(payload.title)
                        .font(.headline)
                    Text(loadStateText)
                        .font(.footnote)
                        .foregroundStyle(loadStateColor)
                }

                Button("Close") {
                    state.closeTerminal()
                }
                .buttonStyle(.bordered)
            }

            if let url = payload.url {
                CompanionWebView(url: url, loadState: $state.terminalLoadState)
                    .id(payload.id)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ContentUnavailableView(
                    "Invalid Terminal URL",
                    systemImage: "exclamationmark.triangle",
                    description: Text("SlopZooka could not open the terminal surface.")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            }

            terminalUtilitiesSection(payload: payload)
        }
        .padding(20)
        .onAppear {
            slzLog("terminalMode appeared \(payload.id)")
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var debugLogView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug Log")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(debugLog.entries.suffix(20).enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 180)
        }
        .padding(16)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func terminalUtilitiesSection(payload: TerminalWindowPayload) -> some View {
        DisclosureGroup(isExpanded: $isTerminalUtilitiesExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                Text(payload.urlString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                Text("If this view is visible, the native state transition worked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                debugLogView
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Session Details")
                    .font(.headline)
                Spacer()
                Text(isTerminalUtilitiesExpanded ? "Hide" : "Show")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var loadStateText: String {
        switch state.terminalLoadState {
        case .idle:
            return "Terminal idle."
        case let .loading(url):
            return "Loading terminal: \(url)"
        case .loaded:
            return "Terminal loaded."
        case let .failed(message):
            return "Terminal failed: \(message)"
        }
    }

    private var loadStateColor: AnyShapeStyle {
        switch state.terminalLoadState {
        case .failed:
            return AnyShapeStyle(.red)
        case .loaded:
            return AnyShapeStyle(.green)
        case .idle, .loading:
            return AnyShapeStyle(.secondary)
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch state.workspaceState {
        case .idle:
            ContentUnavailableView(
                "No Workspaces Yet",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Launch a repo once and it will show up here for quick reopen.")
            )
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading saved workspaces...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case let .failure(message):
            ContentUnavailableView(
                "Workspace Load Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded:
            if state.recentWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No Saved Workspaces",
                    systemImage: "square.stack.3d.up",
                    description: Text("Launch a repo to create your first workspace.")
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(state.recentWorkspaces) { workspace in
                        Button {
                            Task {
                                await state.reopen(workspace)
                            }
                        } label: {
                            WorkspaceRowView(
                                workspace: workspace,
                                selectedTool: state.selectedTool,
                                isBusy: state.busyWorkspaceID == workspace.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var repoContent: some View {
        switch state.repoState {
        case .idle:
            ContentUnavailableView(
                "No Repositories Yet",
                systemImage: "folder.badge.questionmark",
                description: Text("Connect to your Mac companion to load recent GitHub repositories.")
            )
        case .loading:
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                Text("Loading recent repositories...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case let .failure(message):
            ContentUnavailableView(
                "Repository Load Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded:
            if state.filteredRepos.isEmpty {
                ContentUnavailableView(
                    "No Matching Repositories",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search or refresh your recent repo list.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.filteredRepos) { repo in
                            Button {
                                Task {
                                    await state.launch(repo)
                                }
                            } label: {
                                RepoRowView(
                                    repo: repo,
                                    isBusy: state.busyRepoID == repo.id,
                                    isSelectedToolTerminal: state.selectedTool == .terminal
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

enum RepoState {
    case idle
    case loading
    case loaded(viewerLogin: String, count: Int)
    case failure(String)
}

enum WorkspaceState {
    case idle
    case loading
    case loaded(count: Int)
    case failure(String)
}

#Preview(windowStyle: .automatic) {
    ContentView()
}
