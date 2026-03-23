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
    @Published var mutatingWorkspaceID: String?
    @Published var isPruningMissingWorkspaces = false
    @Published var feedback: LaunchFeedback?

    private let userDefaults = UserDefaults.standard
    private var autoConnectInFlight = false
    private var lastAutoConnectHost: String?
    private var lastAutoConnectAttemptAt: Date?
    private let autoConnectCooldown: TimeInterval = 6
    private let healthRequestTimeout: TimeInterval = 4
    private let dataRequestTimeout: TimeInterval = 15
    var onTerminalLaunch: ((TerminalWindowPayload) -> Void)?

    var isMutatingWorkspace: Bool {
        mutatingWorkspaceID != nil || isPruningMissingWorkspaces
    }

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
            let message = transportMessage(from: error)
            healthState = .failure(message)
            slzLog("health check error \(message)")
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
            let message = transportMessage(from: error)
            repoState = .failure(message)
            slzLog("loadRecentRepos error \(message)")
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
            let message = transportMessage(from: error)
            workspaceState = .failure(message)
            slzLog("loadWorkspaces error \(message)")
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
        feedback = nil
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
                feedback = LaunchFeedback(message: "Workspace launch failed: no HTTP response.", style: .error)
                slzLog("launch failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                feedback = LaunchFeedback(message: message, style: .error)
                slzLog("launch failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(LaunchWorkspaceResponse.self, from: data)
            applyLaunchPayload(payload)
            await loadWorkspaces()
        } catch {
            let message = transportMessage(from: error)
            feedback = LaunchFeedback(message: message, style: .error)
            slzLog("launch error \(message)")
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
        feedback = nil
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
                feedback = LaunchFeedback(message: "Workspace reopen failed: no HTTP response.", style: .error)
                slzLog("reopen failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                feedback = LaunchFeedback(message: message, style: .error)
                slzLog("reopen failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(LaunchWorkspaceResponse.self, from: data)
            applyLaunchPayload(payload)
            await loadWorkspaces()
        } catch {
            let message = transportMessage(from: error)
            feedback = LaunchFeedback(message: message, style: .error)
            slzLog("reopen error \(message)")
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

        feedback = LaunchFeedback(message: "Opening demo session.", style: .neutral)
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
            feedback = LaunchFeedback(message: "Workspace launched, but terminal URL was invalid.", style: .error)
            slzLog("launch failed: invalid terminal URL \(payload.launchURL)")
            return
        }

        feedback = LaunchFeedback(
            message: "\(payload.repo.nameWithOwner) • \(payload.baseRef) → \(payload.branchName)",
            style: .success
        )
        let terminalPayload = TerminalWindowPayload(
            id: payload.clusterId,
            title: "\(selectedTool.title) • \(payload.repo.nameWithOwner)",
            urlString: terminalURL.absoluteString
        )
        onTerminalLaunch?(terminalPayload)
        slzLog("active terminal assigned \(terminalPayload.id)")
    }

    func archive(_ workspace: WorkspaceSummary) async {
        guard !normalizedHost.isEmpty else {
            healthState = .failure("Enter a companion host first.")
            slzLog("archive blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/workspaces/\(workspace.id)/archive") else {
            healthState = .failure("Invalid host.")
            slzLog("archive blocked: invalid host \(normalizedHost)")
            return
        }

        mutatingWorkspaceID = workspace.id
        feedback = nil
        slzLog("archive start workspace=\(workspace.id) repo=\(workspace.repo.nameWithOwner)")

        defer {
            mutatingWorkspaceID = nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = dataRequestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                feedback = LaunchFeedback(message: "Archive failed: no HTTP response.", style: .error)
                slzLog("archive failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                feedback = LaunchFeedback(message: message, style: .error)
                slzLog("archive failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(ArchiveWorkspaceResponse.self, from: data)
            recentWorkspaces.removeAll { $0.id == payload.workspace.id }
            workspaceState = .loaded(count: max(0, recentWorkspaces.count))
            feedback = LaunchFeedback(message: "Archived \(payload.workspace.repo.nameWithOwner).", style: .success)
            slzLog("archive success workspace=\(payload.workspace.id)")
            await loadWorkspaces()
        } catch {
            let message = transportMessage(from: error)
            feedback = LaunchFeedback(message: message, style: .error)
            slzLog("archive error \(message)")
        }
    }

    func pruneMissingWorkspaces() async {
        guard !normalizedHost.isEmpty else {
            healthState = .failure("Enter a companion host first.")
            slzLog("pruneMissingWorkspaces blocked: empty host")
            return
        }

        guard let url = companionURL(path: "/api/workspaces/prune-missing") else {
            healthState = .failure("Invalid host.")
            slzLog("pruneMissingWorkspaces blocked: invalid host \(normalizedHost)")
            return
        }

        isPruningMissingWorkspaces = true
        feedback = nil
        slzLog("pruneMissingWorkspaces start")

        defer {
            isPruningMissingWorkspaces = false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = dataRequestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                feedback = LaunchFeedback(message: "Prune failed: no HTTP response.", style: .error)
                slzLog("pruneMissingWorkspaces failed: no HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = decodeAPIError(data: data, statusCode: httpResponse.statusCode)
                feedback = LaunchFeedback(message: message, style: .error)
                slzLog("pruneMissingWorkspaces failed status=\(httpResponse.statusCode) message=\(message)")
                return
            }

            let payload = try JSONDecoder().decode(PruneMissingWorkspacesResponse.self, from: data)
            if payload.archivedCount == 0 {
                feedback = LaunchFeedback(message: "No missing workspaces to hide.", style: .neutral)
            } else {
                feedback = LaunchFeedback(message: "Hidden \(payload.archivedCount) missing workspace\(payload.archivedCount == 1 ? "" : "s").", style: .success)
            }
            slzLog("pruneMissingWorkspaces success archivedCount=\(payload.archivedCount)")
            await loadWorkspaces()
        } catch {
            let message = transportMessage(from: error)
            feedback = LaunchFeedback(message: message, style: .error)
            slzLog("pruneMissingWorkspaces error \(message)")
        }
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

    private func transportMessage(from error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }

        switch urlError.code {
        case .timedOut:
            return "Request timed out. Check that the companion is running and reachable."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Could not reach the companion host."
        case .notConnectedToInternet, .networkConnectionLost:
            return "Network connection dropped while talking to the companion."
        default:
            return urlError.localizedDescription
        }
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
        ScrollView {
            launcherMode
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
        }
        .scrollIndicators(.hidden)
        .frame(width: launcherWindowSize.width, height: launcherWindowSize.height)
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
            }

            if let feedback = state.feedback {
                feedbackBanner(feedback)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                        .disabled(state.isMutatingWorkspace)

                        Button("Demo") {
                            state.openDemoSession()
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isMutatingWorkspace)

                        Button("Palm Spike") {
                            openWindow(id: "palm-spike")
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isMutatingWorkspace)
                    }

                    HStack(spacing: 10) {
                        Button(state.isPruningMissingWorkspaces ? "Hiding Missing..." : "Hide Missing") {
                            Task {
                                await state.pruneMissingWorkspaces()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isMutatingWorkspace)

                        if state.feedback != nil {
                            Button("Clear Status") {
                                state.feedback = nil
                            }
                            .buttonStyle(.bordered)
                        }
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
                        HStack(spacing: 10) {
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
                            .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)

                            Menu {
                                Button(workspace.existsOnDisk ? "Archive Workspace" : "Hide Missing Workspace", role: .destructive) {
                                    Task {
                                        await state.archive(workspace)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .background(.quaternary.opacity(0.35), in: Circle())
                            }
                            .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)
                        }
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
                        .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)
                    }
                }
            }
        }
    }

    private func feedbackBanner(_ feedback: LaunchFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedbackIconName(for: feedback.style))
                .foregroundStyle(feedbackColor(for: feedback.style))

            Text(feedback.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func feedbackColor(for style: LaunchFeedback.Style) -> AnyShapeStyle {
        switch style {
        case .neutral:
            return AnyShapeStyle(.secondary)
        case .success:
            return AnyShapeStyle(.green)
        case .error:
            return AnyShapeStyle(.orange)
        }
    }

    private func feedbackIconName(for style: LaunchFeedback.Style) -> String {
        switch style {
        case .neutral:
            return "info.circle"
        case .success:
            return "checkmark.circle"
        case .error:
            return "exclamationmark.triangle"
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
