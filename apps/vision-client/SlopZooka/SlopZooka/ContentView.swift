import SwiftUI

struct ContentView: View {
    private let launcherWindowSize = CGSize(width: 620, height: 760)

    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var state: LauncherState
    @AppStorage("launcherSection") private var section: LauncherSection = .projects
    private enum Sheet: String, Identifiable {
        case settings, newRepo
        var id: String { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var createRepoTask: Task<Void, Never>?
    @FocusState private var projectSearchFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            launcherHeader
            if state.isReady {
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
            case .settings:
                LauncherSettingsView()
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

    private var launcherHeader: some View {
        HStack {
            Text("SlopZooka").font(.title2.weight(.semibold))
            Spacer()
            Image(systemName: "desktopcomputer")
                .foregroundStyle(state.isReady ? Color.green : Color.secondary)
                .accessibilityLabel(state.isReady ? "Mac connected" : "Mac disconnected")
                .help(state.isReady ? "Mac connected" : "Mac disconnected")
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Settings")
            .help("Settings")
        }
    }

    private var launcherMode: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let feedback = state.feedback { feedbackBanner(feedback) }
            if let error = windows.persistenceError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            if !state.isReady {
                if activeSheet != .settings { MacConnectionView() }
            } else {
                switch section {
                case .sessions:
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading("Your terminals", count: windows.terminalSessions.count)
                        Text("Reopen a session without interrupting what’s running.")
                            .font(.footnote).foregroundStyle(.secondary)
                        quickOpenSessionsContent
                        if windows.terminalSessions.isEmpty {
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

    @ViewBuilder
    private var quickOpenSessionsContent: some View {
        if windows.terminalSessions.isEmpty {
            compactEmptyView("No open terminal sessions.")
        } else {
            LazyVStack(spacing: 10) {
                ForEach(windows.terminalSessions) { session in
                    Button {
                        do { try windows.open(id: session.id) }
                        catch { state.feedback = LaunchFeedback(message: error.localizedDescription, style: .error) }
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
        case .disconnected:
            return "Mac companion disconnected"
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
