import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var client: CompanionClient
    @AppStorage("launcherSection") private var section: LauncherSection = .repos
    private enum Sheet: String, Identifiable {
        case settings, newRepo, connection
        var id: String { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var createRepoTask: Task<Void, Never>?
    @FocusState private var projectSearchFocused: Bool

    var body: some View {
        Group {
            if client.hasWorkspace {
                workspace.frame(width: 910, height: 580)
            } else {
                MacConnectionFlow(isSetup: true)
                    .frame(width: 550, height: 480)
            }
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 32))
        .sheet(item: $activeSheet, onDismiss: {
            createRepoTask?.cancel()
            createRepoTask = nil
            state.cancelRepoCreation()
        }) { sheet in
            switch sheet {
            case .settings:
                LauncherSettingsView()
            case .connection:
                MacConnectionFlow(isSetup: false)
                    .frame(width: 540, height: 620)
            case .newRepo:
                NewRepoSheetView(
                    owners: state.availableOwners,
                    ownersUnavailable: state.ownersUnavailable,
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
        .onChange(of: section) { _, _ in state.searchText = "" }
        .onChange(of: state.selectedTool) { _, _ in
            state.persistSelectedTool()
        }
    }

    private enum LauncherSection: String, CaseIterable, Identifiable {
        case repos = "Projects", worktrees = "Terminals", threads = "Threads", frontends = "Frontends"
        var id: Self { self }
        var title: String {
            switch self {
            case .repos: "Repos"
            case .worktrees: "Worktrees"
            default: rawValue
            }
        }
        var icon: String {
            switch self {
            case .repos: "folder"
            case .worktrees: "point.topleft.down.to.point.bottomright.curvepath"
            case .threads: "text.bubble"
            case .frontends: "globe"
            }
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("SlopZooka").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader).padding(.horizontal, 12)
                VStack(spacing: 4) {
                    ForEach(LauncherSection.allCases) { item in
                        if item == .frontends { Divider().padding(.vertical, 8) }
                        sidebarRow(item.title, icon: item.icon, selected: section == item) { section = item }
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    sidebarRow("Ask SlopZooka", icon: "mic") { windows.openCoordinator() }
                    sidebarRow("Settings", icon: "gearshape") { activeSheet = .settings }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 24).frame(width: 230)
            .background(.black.opacity(0.12))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(section.title).font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        activeSheet = .connection
                    } label: {
                        Label {
                            Text(client.launcherConnectionLabel)
                        } icon: {
                            Image(systemName: client.isReady || client.isActivelyReconnecting
                                  ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                                .foregroundStyle(client.isActivelyReconnecting ? Color.cyan : (client.isReady ? .primary : .orange))
                                .overlay {
                                    if client.isActivelyReconnecting { ConnectionActivityRing().frame(width: 25, height: 25) }
                                }
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens connection controls")
                }
                .padding(.horizontal, 36).padding(.vertical, 24)
                Divider()
                ScrollView {
                    launcherMode.frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 36).padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return Button(action: action) {
            Label {
                Text(title).font(.body.weight(selected ? .semibold : .regular))
            } icon: {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.cyan : Color.secondary)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(.white.opacity(selected ? 0.16 : 0), in: shape)
            .contentShape([.interaction, .hoverEffect], shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let feedback = state.feedback { feedbackBanner(feedback) }
            switch section {
            case .repos:
                projectsContent
            case .worktrees:
                worktreesContent
            case .threads:
                HStack {
                    sectionHeading("Recent Codex threads", count: state.filteredCodexThreads.count)
                    Button {
                        if let hostID = client.current?.id { Task { await state.loadCodexThreads(hostID: hostID) } }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .disabled(!client.isReady)
                    .accessibilityLabel("Refresh Codex threads")
                }
                searchField("Search threads or repos")
                codexThreadsContent.disabled(!client.isReady)
            case .frontends:
                FrontendListView(hostID: state.catalogHostID).disabled(!client.isReady)
            }
        }
    }

    private var worktreesContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                toolPicker
                Spacer()
                if !windows.terminalSessions.isEmpty {
                    Menu("Reopen Terminal", systemImage: "terminal") {
                        ForEach(windows.terminalSessions) { session in
                            Button(session.payload.displayTitle) {
                                do { try windows.open(id: session.id) }
                                catch { state.feedback = LaunchFeedback(message: error.localizedDescription, style: .error) }
                            }
                        }
                    }
                    .disabled(!client.isReady)
                }
                Menu("Manage Worktrees", systemImage: "ellipsis") {
                    Button("Hide Missing Worktrees") { Task { await state.pruneMissingWorkspaces() } }
                }
                .disabled(!client.isReady || state.isMutatingWorkspace)
            }
            searchField("Search worktrees or branches")
            quickWorkspaceContent
        }
    }

    private var toolPicker: some View {
        Picker("Open with", selection: $state.selectedTool) {
            ForEach(LaunchTarget.allCases) { target in Text(target.title).tag(target) }
        }.pickerStyle(.menu)
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                toolPicker
                Spacer()
                Button("New Repo…", systemImage: "plus") {
                    state.repoCreationError = nil
                    activeSheet = .newRepo
                }
                .disabled(!client.isReady || state.isMutatingWorkspace)
            }
            searchField("Search repos")
            if state.repoState.value?.githubUnavailable == true {
                HStack {
                    Text("GitHub repos are unavailable on your Mac.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        if let hostID = client.current?.id { Task { await state.loadRepositories(hostID: hostID) } }
                    }
                    .disabled(!client.isReady)
                }
                .font(.footnote)
            }
            quickRepoContent.disabled(!client.isReady)
        }
    }

    private func searchField(_ prompt: String) -> some View {
        HStack(spacing: 12) {
            TextField(prompt, text: $state.searchText)
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
    }

    @ViewBuilder
    private var codexThreadsContent: some View {
        switch state.codexState {
        case .idle, .loading:
            compactLoadingView(title: "Loading Codex threads...")
        case .failure(let message):
            compactFailureView(message: message)
        case .loaded:
            if state.filteredCodexThreads.isEmpty {
                compactEmptyView(state.searchText.isEmpty ? "No saved Codex threads." : "No matching Codex threads.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(state.filteredCodexThreads) { thread in
                        let repository = state.threadRepository(thread)
                        let project = repository?.replacingOccurrences(of: "~local/", with: "", options: .anchored)
                            ?? thread.folderName
                        Button {
                            projectSearchFocused = false
                            Task { await state.resume(thread) }
                        } label: {
                            HStack(spacing: 12) {
                                RepositoryAvatar(owner: repository.flatMap(state.threadAvatarOwner), hostID: state.catalogHostID,
                                                 fallbackIcon: repository == nil ? "text.bubble" : "folder")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(project).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    if !thread.available {
                                        Text("Missing on Mac").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 0)
                                if state.busyThreadID == thread.id {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    TimelineView(.periodic(from: .now, by: 60)) { context in
                                        Text(thread.age(at: context.date))
                                    }
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.quaternary, in: Capsule())
                                    Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffectDisabled()
                        .disabled(state.isMutatingWorkspace || !thread.available)
                        .accessibilityHint(thread.available ? "Resumes this Codex thread" : "The folder is missing on the Mac")
                        .modifier(LauncherRowSurface())
                    }
                }
            }
        }
    }

    private var matchingWorkspaces: [WorkspaceSummary] {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.recentWorkspaces.filter {
            query.isEmpty || $0.repo.nameWithOwner.localizedCaseInsensitiveContains(query)
                || $0.branchName.localizedCaseInsensitiveContains(query)
                || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if count > 0 { Text(count, format: .number).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var quickWorkspaceContent: some View {
        switch state.workspaceState {
        case .idle, .loading:
            compactLoadingView(title: "Loading worktrees...")
        case .failure(let message):
            compactFailureView(message: message)
        case .loaded:
            if matchingWorkspaces.isEmpty {
                compactEmptyView(
                    state.searchText.isEmpty ? "Your worktrees will appear here." : "No matching worktrees.")
            } else {
                let groups = Dictionary(grouping: matchingWorkspaces) { $0.repo.nameWithOwner }
                let order = orderedWorktreeRepos(in: groups)
                let sessions = windows.terminalSessions.filter { windows.reference(for: $0.id)?.hostID == state.catalogHostID }
                let sessionsByWorktree = Dictionary(grouping: sessions, by: \.payload.workspaceId)
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(order, id: \.self) { repo in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(repo).font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(groups[repo] ?? []) { workspace in
                                workspaceRow(workspace, sessionCount: sessionsByWorktree[workspace.id]?.count ?? 0)
                            }
                        }
                    }
                }
            }
        }
    }

    private func orderedWorktreeRepos(in groups: [String: [WorkspaceSummary]]) -> [String] {
        var remaining = Set(groups.keys)
        let catalogOrder = state.recentRepos.map(\.nameWithOwner).filter { remaining.remove($0) != nil }
        return catalogOrder + remaining.sorted()
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: WorkspaceSummary, sessionCount: Int) -> some View {
        if client.isReady {
            HStack(spacing: 0) {
                Button {
                    projectSearchFocused = false
                    Task { await state.reopen(workspace) }
                } label: {
                    WorkspaceRowView(workspace: workspace, selectedTool: state.selectedTool,
                                     hostID: state.catalogHostID, isBusy: state.busyWorkspaceID == workspace.id, sessionCount: sessionCount)
                }
                .buttonStyle(.plain)
                .hoverEffectDisabled()
                .disabled(state.isMutatingWorkspace)
                Menu {
                    Button(workspace.existsOnDisk ? "Archive Worktree" : "Hide Missing Worktree", role: .destructive) {
                        Task { await state.archive(workspace) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Options for \(workspace.name ?? workspace.branchName)")
                .padding(.trailing, 8)
                .disabled(state.isMutatingWorkspace)
            }
            .modifier(LauncherRowSurface())
        } else {
            WorkspaceRowView(workspace: workspace, selectedTool: state.selectedTool, hostID: state.catalogHostID, isBusy: false,
                             sessionCount: sessionCount, lastKnown: true)
                .modifier(LauncherRowSurface(interactive: false))
        }
    }

    @ViewBuilder
    private var quickRepoContent: some View {
        switch state.repoState {
        case .idle, .loading:
            compactLoadingView(title: "Loading repos...")
        case .failure(let message):
            compactFailureView(message: message)
        case .loaded:
            let quickRepos = state.filteredRepos

            if quickRepos.isEmpty {
                compactEmptyView(state.searchText.isEmpty ? "No recent repos yet." : "No matching repos.")
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
                                    hostID: state.catalogHostID,
                                    isBusy: state.busyRepoID == repo.id,
                                    isSelectedToolTerminal: state.selectedTool == .terminal
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverEffectDisabled()
                            .disabled(state.isMutatingWorkspace)
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
                .accessibilityHidden(true)

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
}
