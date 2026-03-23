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

    private let userDefaults = UserDefaults.standard
    private var autoConnectInFlight = false
    private var lastAutoConnectHost: String?
    private var lastAutoConnectAttemptAt: Date?
    private let autoConnectCooldown: TimeInterval = 6
    private let healthRequestTimeout: TimeInterval = 4
    private let dataRequestTimeout: TimeInterval = 15
    var onTerminalLaunch: ((TerminalWindowPayload) -> Void)?

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

    func loadSavedPreferences() {
        loadSavedHost()

        if let savedTool = userDefaults.string(forKey: "selectedTool"),
           let launchTarget = LaunchTarget(rawValue: savedTool) {
            selectedTool = launchTarget
            slzLog("loaded saved tool \(savedTool)")
        } else {
            slzLog("no saved tool found")
        }
    }

    func persistSelectedTool() {
        userDefaults.set(selectedTool.rawValue, forKey: "selectedTool")
    }

    func loadSavedHost() {
        if let savedHost = userDefaults.string(forKey: "companionHost"), !savedHost.isEmpty {
            host = savedHost
            slzLog("loaded saved host \(savedHost)")
        } else {
            slzLog("no saved host found")
        }
    }

    func maybeAutoConnect(candidateHost: String, reason: String) async {
        let candidateHost = candidateHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateHost.isEmpty else {
            return
        }

        guard !autoConnectInFlight else {
            slzLog("auto-connect skipped: already in flight")
            return
        }

        if case .success = healthState, normalizedHost == candidateHost {
            return
        }

        if let lastAutoConnectHost,
           lastAutoConnectHost == candidateHost,
           let lastAutoConnectAttemptAt,
           Date().timeIntervalSince(lastAutoConnectAttemptAt) < autoConnectCooldown {
            return
        }

        autoConnectInFlight = true
        lastAutoConnectHost = candidateHost
        lastAutoConnectAttemptAt = Date()

        if host != candidateHost {
            host = candidateHost
        }

        slzLog("auto-connect start reason=\(reason) host=\(candidateHost)")

        defer {
            autoConnectInFlight = false
        }

        _ = await connectAndRefresh()
    }

    func maybeAutoConnect(candidateHosts: [String], reason: String) async {
        let normalizedCandidates = Array(
            Set(
                candidateHosts
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )

        guard !normalizedCandidates.isEmpty else {
            return
        }

        guard !autoConnectInFlight else {
            slzLog("auto-connect skipped: already in flight")
            return
        }

        autoConnectInFlight = true
        defer {
            autoConnectInFlight = false
        }

        for candidateHost in normalizedCandidates {
            if let lastAutoConnectHost,
               lastAutoConnectHost == candidateHost,
               let lastAutoConnectAttemptAt,
               Date().timeIntervalSince(lastAutoConnectAttemptAt) < autoConnectCooldown {
                continue
            }

            lastAutoConnectHost = candidateHost
            lastAutoConnectAttemptAt = Date()

            if host != candidateHost {
                host = candidateHost
            }

            slzLog("auto-connect start reason=\(reason) host=\(candidateHost)")

            let didConnect = await connectAndRefresh()
            if didConnect {
                return
            }
        }
    }

    func connectAndRefresh() async -> Bool {
        slzLog("connectAndRefresh start host=\(normalizedHost)")
        let didConnect = await runHealthCheck()
        guard didConnect else {
            repoState = .idle
            workspaceState = .idle
            recentRepos = []
            recentWorkspaces = []
            slzLog("connectAndRefresh failed")
            return false
        }

        async let reposTask: Void = loadRecentRepos()
        async let workspacesTask: Void = loadWorkspaces()
        _ = await (reposTask, workspacesTask)
        return true
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
            var request = URLRequest(url: url)
            request.timeoutInterval = healthRequestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
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
            var request = URLRequest(url: url)
            request.timeoutInterval = dataRequestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
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
            var request = URLRequest(url: url)
            request.timeoutInterval = dataRequestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
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
            request.timeoutInterval = dataRequestTimeout
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
            request.timeoutInterval = dataRequestTimeout
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

        launchMessage = "Opening demo session."
        let payload = TerminalWindowPayload(
            id: UUID().uuidString,
            title: "Demo Session",
            urlString: urlString
        )
        onTerminalLaunch?(payload)
        slzLog("openDemoSession \(urlString)")
    }

    private func applyLaunchPayload(_ payload: LaunchWorkspaceResponse) {
        slzLog("launch response repo=\(payload.repo.nameWithOwner) branch=\(payload.branchName) url=\(payload.launchURL)")

        guard let terminalURL = URL(string: payload.launchURL) else {
            launchMessage = "Workspace launched, but terminal URL was invalid."
            slzLog("launch failed: invalid terminal URL \(payload.launchURL)")
            return
        }

        launchMessage = "\(payload.repo.nameWithOwner) • \(payload.baseRef) → \(payload.branchName)"
        let terminalPayload = TerminalWindowPayload(
            id: payload.clusterId,
            title: "\(selectedTool.title) • \(payload.repo.nameWithOwner)",
            urlString: terminalURL.absoluteString
        )
        onTerminalLaunch?(terminalPayload)
        slzLog("active terminal assigned \(terminalPayload.id)")
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
    private let debugBuildStamp = "quick-launch-v1 2026-03-22 23:45"
    private let launcherWindowSize = CGSize(width: 460, height: 680)

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var state = LauncherState()
    @StateObject private var discovery = CompanionDiscovery()
    @State private var isMoreExpanded = false

    var body: some View {
        launcherMode
            .frame(width: launcherWindowSize.width, height: launcherWindowSize.height)
            .padding(20)
            .task {
                state.onTerminalLaunch = { payload in
                    appModel.registerTerminal(payload)
                    openWindow(id: "terminal", value: payload.id)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        dismiss()
                    }
                }
                state.loadSavedPreferences()
                discovery.onCompanionResolved = { companion in
                    Task {
                        await state.maybeAutoConnect(candidateHosts: companion.candidateHosts, reason: "bonjour_callback")
                    }
                }
                discovery.start()
                if !state.normalizedHost.isEmpty {
                    await state.maybeAutoConnect(candidateHost: state.normalizedHost, reason: "saved_host")
                }
                slzLog("ContentView task completed")
            }
            .onAppear {
                slzLog("ContentView appeared")
            }
            .onDisappear {
                discovery.stop()
            }
            .onChange(of: state.selectedTool) { _, _ in
                state.persistSelectedTool()
            }
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Launch")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Pick a tool and tap a repo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let launchMessage = state.launchMessage {
                    Text(launchMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
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
            .padding(16)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Workspaces")
                        .font(.headline)

                    Spacer()

                    if case let .loaded(count) = state.workspaceState {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                quickWorkspaceContent
            }
            .padding(16)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(state.searchText.isEmpty ? "Recent Repositories" : "Search Results")
                        .font(.headline)

                    Spacer()

                    if case let .loaded(viewerLogin, count) = state.repoState {
                        Text("\(count) from \(viewerLogin)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                quickRepoContent
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            DisclosureGroup(isExpanded: $isMoreExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search owner or repo", text: $state.searchText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Companion Host")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("MacName.local:7777", text: $state.host)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    HStack(spacing: 10) {
                        Button("Reconnect") {
                            Task {
                                await state.connectAndRefresh()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Demo") {
                            state.openDemoSession()
                        }
                        .buttonStyle(.bordered)

                        Button("Palm Spike") {
                            openWindow(id: "palm-spike")
                        }
                        .buttonStyle(.bordered)
                    }

                    discoveryStatusView
                    HealthStatusView(state: state.healthState)

                    Text("Build: \(debugBuildStamp)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private var discoveryStatusView: some View {
        switch discovery.state {
        case .idle:
            EmptyView()
        case .searching:
            Label("Searching for a nearby Mac companion…", systemImage: "dot.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .found(count):
            let hostText = discovery.preferredHost ?? "nearby companion"
            Label("Discovered \(count) companion\(count == 1 ? "" : "s"). Auto-connecting to \(hostText).", systemImage: "network")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var quickWorkspaceContent: some View {
        switch state.workspaceState {
        case .idle, .loading:
            compactLoadingView(title: "Loading workspaces...")
        case let .failure(message):
            compactFailureView(message: message)
        case .loaded:
            if state.recentWorkspaces.isEmpty {
                compactEmptyView("No saved workspaces yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(state.recentWorkspaces.prefix(4))) { workspace in
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
    private var quickRepoContent: some View {
        switch state.repoState {
        case .idle, .loading:
            compactLoadingView(title: "Loading repositories...")
        case let .failure(message):
            compactFailureView(message: message)
        case .loaded:
            let quickRepos = Array((state.searchText.isEmpty ? state.recentRepos : state.filteredRepos).prefix(state.searchText.isEmpty ? 6 : 10))

            if quickRepos.isEmpty {
                compactEmptyView(state.searchText.isEmpty ? "No recent repositories yet." : "No matching repositories.")
            } else {
                VStack(spacing: 10) {
                    ForEach(quickRepos) { repo in
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
            }
        }
    }

    private func compactLoadingView(title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()

            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func compactFailureView(message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func compactEmptyView(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
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
