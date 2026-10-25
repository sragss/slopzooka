import SwiftUI

struct ContentView: View {
    private let launcherWindowSize = CGSize(width: 620, height: 760)

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var state = LauncherState()
    @StateObject private var discovery = CompanionDiscovery()
    @AppStorage("launcherSection") private var section: LauncherSection = .projects
    @State private var isConnectionPresented = false
    @State private var connectionHost = ""
    @State private var isNewRepoPresented = false

    var body: some View {
        VStack(spacing: 16) {
            launcherHeader
            if isReady {
                Picker("Browse", selection: $section) {
                    ForEach(LauncherSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }.pickerStyle(.segmented)
            }
            ScrollView {
                launcherMode.frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollIndicators(.hidden)
        }
        .padding(24)
        .frame(width: launcherWindowSize.width, height: launcherWindowSize.height)
        .sheet(isPresented: $isConnectionPresented) {
            NavigationStack {
                ScrollView { connectionContent.padding(24) }
                    .navigationTitle("Mac connection")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isConnectionPresented = false }
                        }
                    }
            }.frame(width: 520, height: 500)
        }
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
        .onChange(of: state.host) { old, new in
            if connectionHost.isEmpty || connectionHost == old { connectionHost = new }
        }
        .onChange(of: isReady) { _, ready in
            if ready { isConnectionPresented = false }
        }
        .onChange(of: state.selectedTool) { _, _ in
            state.persistSelectedTool()
        }
    }

    private enum LauncherSection: String, CaseIterable, Identifiable {
        case sessions = "Terminals"
        case projects = "Projects"
        case frontends = "Frontends"
        var id: String { rawValue }
    }

    private var isReady: Bool {
        if case .success = state.healthState { return !state.needsPairing }
        return false
    }

    private var launcherHeader: some View {
        HStack {
            Text("SlopZooka").font(.title2.weight(.semibold))
            Spacer()
            if isReady {
                Button { isConnectionPresented = true } label: {
                    Label("Mac", systemImage: "desktopcomputer").font(.subheadline)
                }.buttonStyle(.bordered)
            }
        }
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let feedback = state.feedback { feedbackBanner(feedback) }
            if !isReady {
                connectionContent
            } else {
                switch section {
                case .sessions:
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading("Your terminals", count: appModel.openTerminalSessions.count)
                        Text("Reopen a session without interrupting what’s running.")
                            .font(.footnote).foregroundStyle(.secondary)
                        quickOpenSessionsContent
                        if appModel.openTerminalSessions.isEmpty {
                            Button("Open a Project") { section = .projects }.buttonStyle(.borderedProminent)
                        }
                    }
                case .projects:
                    projectsContent
                case .frontends:
                    FrontendListView(
                        frontends: state.frontends, warning: state.frontendWarning,
                        baseURL: CompanionAPI.baseURL(host: state.normalizedHost))
                }
            }
        }
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("Open with", selection: $state.selectedTool) {
                    ForEach(LaunchTarget.allCases) { target in Text(target.title).tag(target) }
                }.pickerStyle(.menu)
                Spacer()
                Menu {
                    Button("New Repository…") { isNewRepoPresented = true }
                        .disabled(state.availableOwners.isEmpty)
                    Button(state.isPruningMissingWorkspaces ? "Hiding Missing…" : "Hide Missing Workspaces") {
                        Task { await state.pruneMissingWorkspaces() }
                    }
                } label: {
                    Label("Add or manage", systemImage: "plus")
                }
                .disabled(state.isMutatingWorkspace)
            }
            TextField("Search projects or branches", text: $state.searchText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Continue a workspace", count: matchingWorkspaces.count)
                quickWorkspaceContent
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Start from a repository", count: state.filteredRepos.count)
                quickRepoContent
            }
        }
    }

    private var matchingWorkspaces: [WorkspaceSummary] {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.recentWorkspaces.filter {
            query.isEmpty || $0.repo.nameWithOwner.localizedCaseInsensitiveContains(query)
                || $0.branchName.localizedCaseInsensitiveContains(query)
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if count > 0 { Text(count, format: .number).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var selectedMacName: String {
        discovery.companions.first(where: { $0.candidateHosts.contains(state.normalizedHost) })?.name
            ?? state.connection.endpoint?.host() ?? "your Mac"
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if state.needsPairing {
                Text("Connect to \(selectedMacName)").font(.title3.weight(.semibold))
                Text("On your Mac, click the bazooka in the menu bar, then Show Connection Code. Enter the six digits here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    TextField("6-digit code", text: $state.pairingCode)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: state.pairingCode) { _, value in
                            state.pairingCode = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        }
                        .onSubmit { Task { await state.pair() } }
                        .disabled(state.isPairing)
                    Button(state.isPairing ? "Connecting…" : "Connect") { Task { await state.pair() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.pairingCode.count != 6 || state.isPairing)
                }
                if let error = state.pairingError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            } else if !isReady {
                Text("Connect your Mac").font(.title3.weight(.semibold))
                Text("Open SlopZooka on your Mac. It will appear here automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
                discoveryStatusView
                HealthStatusView(state: state.healthState)
            } else {
                Label("Connected to \(selectedMacName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                DisclosureGroup("Connection details") { HealthStatusView(state: state.healthState) }
            }
            DisclosureGroup(isReady ? "Change Mac" : "Can’t find your Mac?") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(discovery.companions) { companion in
                        Button(companion.name) {
                            connectionHost = companion.host
                            state.host = companion.host
                            state.pairingCode = ""
                            state.pairingError = nil
                            Task { await state.connectAndRefresh() }
                        }.disabled(state.isPairing)
                    }
                    Text("Manual address").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("MacName.local:7777", text: $connectionHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Find Mac") {
                            state.host = connectionHost
                            state.pairingCode = ""
                            state.pairingError = nil
                            Task { await state.connectAndRefresh() }
                        }.disabled(state.isPairing || state.isMutatingWorkspace || connectionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.top, 8)
            }.font(.subheadline)
        }
        .onAppear { connectionHost = state.host }
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
            Label(
                "Found \(count) Mac\(count == 1 ? "" : "s"). Checking connection…",
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
            LazyVStack(spacing: 10) {
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
            if matchingWorkspaces.isEmpty {
                compactEmptyView(
                    state.searchText.isEmpty ? "Your opened projects will appear here." : "No matching workspaces.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(matchingWorkspaces) { workspace in
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
            let quickRepos = state.filteredRepos

            if quickRepos.isEmpty {
                compactEmptyView(state.searchText.isEmpty ? "No recent repositories yet." : "No matching repositories.")
            } else {
                LazyVStack(spacing: 10) {
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
            Button {
                state.feedback = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss status")
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
            return session.isPresented ? "Connection needs attention" : "Reopen to reconnect"
        case .loading:
            return session.isPresented ? "Connecting…" : "Reopen to connect"
        case .idle, .loaded:
            if session.isFocused {
                return "Receiving input"
            }
            return session.isPresented ? "Window open" : "Ready to reopen"
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
