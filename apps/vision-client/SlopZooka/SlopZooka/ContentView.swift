import SwiftUI

struct ContentView: View {
    private let debugBuildStamp = "quick-launch-v1 2026-03-22 23:45"
    private let launcherWindowSize = CGSize(width: 620, height: 760)

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var state = LauncherState()
    @StateObject private var discovery = CompanionDiscovery()
    @State private var isMoreExpanded = false
    @State private var isNewRepoPresented = false

    var body: some View {
        ScrollView {
            launcherMode
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
        }
        .scrollIndicators(.hidden)
        .frame(width: launcherWindowSize.width, height: launcherWindowSize.height)
        .sheet(isPresented: $isNewRepoPresented) {
            NewRepoSheetView(
                owners: state.availableOwners,
                suggestedOwnerLogin: state.preferredOwnerLogin(),
                selectedTool: state.selectedTool,
                isSubmitting: state.isCreatingRepo
            ) { owner, repoName, isPrivate in
                Task {
                    let didCreate = await state.createRepoAndLaunch(
                        owner: owner, repoName: repoName, isPrivate: isPrivate)
                    if didCreate {
                        isNewRepoPresented = false
                    }
                }
            }
        }
        .task {
            state.onTerminalLaunch = { payload in
                appModel.registerTerminal(payload)
                openWindow(id: "terminal", value: payload.id)
            }
            state.onSessionSnapshot = { payloads in
                appModel.reconcileTerminals(payloads, host: state.normalizedHost)
            }
            state.loadSavedPreferences()
            discovery.onCompanionResolved = { companion in
                Task {
                    guard state.connection.shouldTry(companion.host) else { return }
                    await state.maybeAutoConnect(candidateHosts: companion.candidateHosts, reason: "bonjour_callback")
                }
            }
            discovery.start()
            if !state.normalizedHost.isEmpty {
                await state.maybeAutoConnect(candidateHost: state.normalizedHost, reason: "saved_host")
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await state.refreshHostCatalog()
            }
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

            if state.needsPairing {
                VStack(alignment: .leading) {
                    Text("Pair with your Mac").font(.headline)
                    Text("Enter the code printed by the companion on your Mac.").font(.caption)
                    HStack {
                        SecureField("Pairing code", text: $state.pairingCode)
                        Button("Pair") { Task { await state.pair() } }
                    }
                }
                .padding(16)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
            }

            FrontendListView(
                frontends: state.frontends, warning: state.frontendWarning,
                baseURL: CompanionAPI.baseURL(host: state.normalizedHost))

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
                    Text("Open Sessions")
                        .font(.headline)

                    Spacer()

                    if !appModel.openTerminalSessions.isEmpty {
                        Text("\(appModel.openTerminalSessions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                quickOpenSessionsContent
            }
            .padding(16)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent Workspaces")
                        .font(.headline)

                    Spacer()

                    if case .loaded(let count) = state.workspaceState {
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

                    Button("New Repo") {
                        isNewRepoPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isMutatingWorkspace || state.availableOwners.isEmpty)

                    if case .loaded(let viewerLogin, let count) = state.repoState {
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
        case .found(let count):
            let hostText = discovery.preferredHost ?? "nearby companion"
            Label(
                "Discovered \(count) companion\(count == 1 ? "" : "s"). Auto-connecting to \(hostText).",
                systemImage: "network"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var quickOpenSessionsContent: some View {
        if appModel.openTerminalSessions.isEmpty {
            compactEmptyView("No open terminal sessions.")
        } else {
            VStack(spacing: 10) {
                ForEach(appModel.openTerminalSessions) { session in
                    Button {
                        openWindow(id: "terminal", value: session.id)
                    } label: {
                        let rowShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(session.payload.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)

                                    if session.isFocused {
                                        Text("Active")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(.green.opacity(0.18), in: Capsule())
                                    }
                                }

                                Text(sessionStateSummary(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowShape.fill(.quaternary.opacity(0.24)))
                        .clipShape(rowShape)
                        .contentShape(rowShape)
                        .contentShape(.hoverEffect, rowShape)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var quickWorkspaceContent: some View {
        switch state.workspaceState {
        case .idle, .loading:
            compactLoadingView(title: "Loading workspaces...")
        case .failure(let message):
            compactFailureView(message: message)
        case .loaded:
            if state.recentWorkspaces.isEmpty {
                compactEmptyView("No saved workspaces yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(state.recentWorkspaces.prefix(4))) { workspace in
                        HStack(spacing: 8) {
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
                            .disabled(
                                state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)

                            Menu {
                                Button(
                                    workspace.existsOnDisk ? "Archive Workspace" : "Hide Missing Workspace",
                                    role: .destructive
                                ) {
                                    Task {
                                        await state.archive(workspace)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.35), in: Circle())
                            }
                            .disabled(
                                state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)
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
        case .failure(let message):
            compactFailureView(message: message)
        case .loaded:
            let quickRepos = Array(
                (state.searchText.isEmpty ? state.recentRepos : state.filteredRepos).prefix(
                    state.searchText.isEmpty ? 6 : 10))

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

    private func sessionStateSummary(_ session: TerminalSessionState) -> String {
        switch session.loadState {
        case .ended:
            return "Session ended"
        case .failed:
            return session.isPresented ? "Visible • failed" : "Hidden • failed"
        case .loading:
            return session.isPresented ? "Visible • loading" : "Hidden • loading"
        case .idle, .loaded:
            if session.isFocused {
                return "Focused"
            }
            return session.isPresented ? "Visible" : "Hidden"
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
