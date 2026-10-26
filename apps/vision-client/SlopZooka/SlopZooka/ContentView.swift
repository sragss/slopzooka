import SwiftUI

struct ContentView: View {
    private let launcherWindowSize = CGSize(width: 620, height: 760)

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var state = LauncherState()
    @StateObject private var discovery = CompanionDiscovery()
    @AppStorage("launcherSection") private var section: LauncherSection = .projects
    private enum Sheet: String, Identifiable {
        case connection, newRepo
        var id: String { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var createRepoTask: Task<Void, Never>?
    @State private var showManualAddress = false
    @FocusState private var pairingCodeFocused: Bool
    @FocusState private var projectSearchFocused: Bool
    @State private var connectionHost = ""

    var body: some View {
        VStack(spacing: 16) {
            launcherHeader
            if isReady {
                HStack(spacing: 4) {
                    ForEach(LauncherSection.allCases) { item in
                        Button { section = item } label: {
                            Text(item.rawValue)
                                .font(.subheadline.weight(section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? .primary : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .tint(.white.opacity(section == item ? 0.18 : 0.04))
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }
                .accessibilityLabel("Browse")
            }
            ScrollView {
                launcherMode.frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollIndicators(.hidden)
        }
        .padding(24)
        .frame(width: launcherWindowSize.width, height: launcherWindowSize.height)
        .sheet(item: $activeSheet, onDismiss: {
            createRepoTask?.cancel()
            createRepoTask = nil
            state.cancelRepoCreation()
        }) { sheet in
            switch sheet {
            case .connection:
                NavigationStack {
                    ScrollView { connectionContent.padding(24) }
                        .navigationTitle("Your Mac")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { activeSheet = nil }
                            }
                        }
                }.frame(width: 520, height: 440)
            case .newRepo:
                NewRepoSheetView(
                    owners: state.availableOwners,
                    suggestedOwnerLogin: state.preferredOwnerLogin(),
                    selectedTool: state.selectedTool,
                    isSubmitting: state.isCreatingRepo,
                    error: state.repoCreationError
                ) { owner, repoName, isPrivate in
                    createRepoTask = Task {
                        let didCreate = await state.createRepoAndLaunch(
                            owner: owner, repoName: repoName, isPrivate: isPrivate)
                        guard !Task.isCancelled else { return }
                        if didCreate { activeSheet = nil }
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
            if ready && activeSheet == .connection { activeSheet = nil }
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
                Button { activeSheet = .connection } label: {
                    Label("Mac", systemImage: "desktopcomputer").font(.subheadline)
                }.buttonStyle(.bordered)
            }
        }
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let feedback = state.feedback { feedbackBanner(feedback) }
            if !isReady {
                if activeSheet != .connection { connectionContent }
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
                    Button("New Repository…") { state.repoCreationError = nil; activeSheet = .newRepo }
                        .disabled(state.availableOwners.isEmpty)
                    Button(state.isPruningMissingWorkspaces ? "Hiding Missing…" : "Hide Missing Workspaces") {
                        Task { await state.pruneMissingWorkspaces() }
                    }
                } label: {
                    Label("Add or manage", systemImage: "plus")
                }
                .disabled(state.isMutatingWorkspace)
            }
            HStack(spacing: 12) {
                TextField("Search projects or branches", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .focused($projectSearchFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .hoverEffectDisabled()
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { projectSearchFocused = true }
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .hoverEffect { effect, isActive, _ in
                        effect.opacity(isActive ? 0.16 : 0.08)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(projectSearchFocused ? 0.4 : 0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
        VStack(alignment: .leading, spacing: 20) {
            if state.needsPairing {
                Text("Connect to \(selectedMacName)").font(.title3.weight(.semibold))
                Text("Enter the six-digit code displayed on your Mac.")
                    .foregroundStyle(.secondary)
                TextField("6-digit code", text: $state.pairingCode)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($pairingCodeFocused)
                    .disabled(state.isPairing)
                    .onChange(of: state.pairingCode) { _, value in
                        let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if value != digits { state.pairingCode = digits; return }
                        if digits.count == 6 { Task { await state.pair() } }
                    }
                    .task(id: state.normalizedHost) {
                        await Task.yield()
                        pairingCodeFocused = true
                        await state.showConnectionCode()
                    }
                    .onChange(of: state.isPairing) { _, pairing in
                        if !pairing { pairingCodeFocused = true }
                    }
                if state.isPairing { ProgressView("Connecting…") }
                if let error = state.pairingError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("You can also find it in the Mac’s bazooka menu → Show Connection Code.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isReady {
                Label(selectedMacName, systemImage: "desktopcomputer").font(.title3.weight(.semibold))
                Text("Connected").foregroundStyle(.secondary)
            } else {
                Text("Find your Mac").font(.title3.weight(.semibold))
                Text("Open SlopZooka on your Mac and use the same Wi-Fi network.")
                    .foregroundStyle(.secondary)
                if case .failure(let message) = state.healthState {
                    Text("Couldn’t reach your Mac.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                    Button("Try Again") { Task { await state.connectAndRefresh() } }
                } else if case .failed(let message) = discovery.state {
                    Text("Mac discovery is unavailable.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                } else {
                    ProgressView("Looking for your Mac…")
                }
            }
            if discovery.companions.count > 1 {
                Menu("Choose another Mac") {
                    ForEach(discovery.companions) { companion in
                        Button(companion.name) { selectMac(companion.host) }
                    }
                }.disabled(state.isPairing || state.isMutatingWorkspace)
            }
            if isReady, case .success(let health) = state.healthState {
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Address: \(health.controlOrigin)")
                        Text("Logs: \(health.logFilePath)")
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button(showManualAddress ? "Hide manual address" : "Enter address manually") {
                showManualAddress.toggle()
            }.font(.subheadline)
            if showManualAddress {
                HStack {
                    TextField("MacName.local:7777", text: $connectionHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find Mac") { selectMac(connectionHost) }
                        .disabled(state.isPairing || state.isMutatingWorkspace || connectionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { connectionHost = state.host }
    }

    private func selectMac(_ host: String) {
        connectionHost = host
        state.host = host
        state.pairingCode = ""
        state.pairingError = nil
        Task { await state.connectAndRefresh() }
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
                        HStack(spacing: 0) {
                            Button {
                                projectSearchFocused = false
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
                            .hoverEffectDisabled()
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
                                Image(systemName: "ellipsis")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 48)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Options for \(workspace.repo.nameWithOwner), \(workspace.branchName)")
                            .padding(.trailing, 8)
                            .disabled(
                                state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)
                        }
                        .modifier(LauncherRowSurface())
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
                        HStack(spacing: 0) {
                            Button {
                                projectSearchFocused = false
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
                            .hoverEffectDisabled()
                            .disabled(state.busyRepoID != nil || state.busyWorkspaceID != nil || state.isMutatingWorkspace)
                        }
                        .modifier(LauncherRowSurface())
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
