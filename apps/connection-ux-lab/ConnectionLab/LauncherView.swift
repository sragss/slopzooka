import SwiftUI

struct LauncherView: View {
    var showControlsOnLaunch = false
    @Environment(LabModel.self) private var lab
    @Environment(\.openWindow) private var openWindow
    @AppStorage("launcherSection") private var section: LauncherSection = .repos
    @State private var presentedSheet: LauncherSheet?
    @State private var search = ""
    @State private var tool = "Codex"

    private enum LauncherSheet: String, Identifiable {
        case settings, connection
        var id: Self { self }
    }

    private enum LauncherSection: String, Identifiable {
        case repos = "Projects", worktrees = "Worktrees", threads = "Threads", frontends = "Frontends"
        static let workspaceSections: [Self] = [.repos, .worktrees, .threads]
        var title: String { self == .repos ? "Repos" : rawValue }
        var id: Self { self }
        var icon: String {
            switch self {
            case .repos: "folder"
            case .worktrees: "point.topleft.down.to.point.bottomright.curvepath"
            case .threads: "text.bubble"
            case .frontends: "globe"
            }
        }
    }

    var body: some View {
        Group {
            if let macName = lab.workspaceMacName {
                workspace(macName: macName)
                    .frame(width: 910, height: 580)
            } else {
                ConnectionFlowView()
                    .id(lab.surfaceRequest)
                    .frame(width: 550, height: 480)
            }
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 32))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings:
                LauncherSettingsView()
            case .connection:
                ConnectionFlowView { presentedSheet = nil }
                    .frame(width: 540, height: 540)
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            Button("Scenarios", systemImage: "slider.horizontal.3") { openWindow(id: "controls") }
                .buttonStyle(.bordered)
                .glassBackgroundEffect(in: Capsule())
                .padding(.top, 12)
        }
        .onChange(of: lab.surfaceRequest, initial: true) { _, _ in showSurface() }
        .task {
            if showControlsOnLaunch { openWindow(id: "controls") }
        }
        .task(id: lab.automaticConnectionID) { [attempt = lab.automaticConnectionID] in
            guard let attempt else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            lab.completeAutomaticConnection(attempt)
        }
    }

    private func workspace(macName: String) -> some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Text(section.title)
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    connectionControl(macName: macName)
                }
                ScrollView {
                    connectedContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
    }

    private func connectionControl(macName: String) -> some View {
        Button {
            presentedSheet = .connection
        } label: {
            Label(connectionLabel(macName), systemImage: lab.isReady ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(lab.isReady ? Color.primary : Color.orange)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Opens connection controls")
    }

    private func connectionLabel(_ macName: String) -> String {
        if lab.isReady { return macName }
        if lab.needsPairing { return "Pairing required" }
        if lab.phase.isReconnecting || lab.phase == .checking { return "Reconnecting to \(macName)…" }
        return "\(macName) disconnected"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("SlopZooka")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12)
            VStack(spacing: 4) {
                ForEach(LauncherSection.workspaceSections) { item in
                    sectionRow(item)
                }
                Divider().padding(.vertical, 8)
                sectionRow(.frontends)
            }
            Spacer()
            VStack(spacing: 4) {
                sidebarRow("Ask SlopZooka", icon: "mic") { openWindow(id: "ask") }
                sidebarRow("Settings", icon: "gearshape") { presentedSheet = .settings }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 24)
        .frame(width: 230)
        .background(.black.opacity(0.12))
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).font(.body.weight(selected ? .semibold : .regular))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.cyan : Color.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(.white.opacity(selected ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionRow(_ item: LauncherSection) -> some View {
        sidebarRow(item.title, icon: item.icon, selected: section == item) {
            section = item
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        switch section {
        case .repos:
            repos
        case .worktrees:
            VStack(alignment: .leading, spacing: 24) {
                ForEach(FixtureEntry.worktreeGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.repository).font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        catalog(group.entries, icon: LauncherSection.worktrees.icon)
                    }
                }
            }
        case .threads:
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Codex threads").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                catalog(FixtureEntry.threads, icon: LauncherSection.threads.icon)
            }
        case .frontends:
            FrontendPermissionView().disabled(!lab.isReady)
        }
    }

    private var repos: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Open with", selection: $tool) {
                ForEach(["Codex", "Claude Code", "OpenCode", "Terminal"], id: \.self) { title in
                    Text(title).tag(title)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 12) {
                TextField("Search repos", text: $search)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .modifier(LabRowSurface())

            let matches = FixtureEntry.repos.filter {
                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    || $0.detail.localizedCaseInsensitiveContains(search)
            }
            if matches.isEmpty {
                Text("No matching repos.").foregroundStyle(.secondary)
            } else {
                catalog(matches, icon: LauncherSection.repos.icon)
            }
        }
    }

    private func catalog(_ entries: [FixtureEntry], icon: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return VStack(spacing: 10) {
            ForEach(entries) { entry in
                Button {
                    openTerminal(entry)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(.quaternary, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(entry.badge)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        Image(systemName: "arrow.up.forward")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: shape)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .contentShape([.interaction, .hoverEffect], shape)
                    .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens a simulated terminal")
            }
        }
        .disabled(!lab.isReady || lab.workspaceBusy)
    }

    private func openTerminal(_ entry: FixtureEntry) {
        guard let mac = lab.workspaceMacName else { return }
        let selectedTool: String
        switch section {
        case .repos: selectedTool = tool
        case .threads: selectedTool = "Codex"
        case .worktrees: selectedTool = entry.badge == "Codex running" ? "Codex" : "Terminal"
        case .frontends: return
        }
        openWindow(id: "fixture-terminal", value: FixtureTerminal(
            mac: mac, entryID: entry.id, title: entry.title, directory: entry.directory, branch: entry.branch, tool: selectedTool
        ))
    }

    private func showSurface() {
        switch lab.surface {
        case .launcher:
            presentedSheet = nil
        case .settings:
            presentedSheet = .settings
        case .yourMac:
            presentedSheet = lab.workspaceMacName == nil ? nil : .connection
        case .frontends:
            presentedSheet = nil
            section = .frontends
        case .ask:
            presentedSheet = nil
            openWindow(id: "ask")
        }
    }
}
