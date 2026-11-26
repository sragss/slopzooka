import SwiftUI

struct LabTerminalWindow: View {
    @Environment(LabModel.self) private var lab
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showActions = false
    @State private var showFrontends = false
    @State private var previewsExpanded = false
    @State private var confirmEnd = false
    @State private var afterActions: (() -> Void)?
    @State private var showReport = false

    var body: some View {
        Group {
            if lab.session == .recovery {
                ContentUnavailableView {
                    Label("Reconnect Window", systemImage: "network")
                } description: {
                    Text("Waiting for the Mac to restore this terminal.")
                } actions: {
                    Button("Retry", action: lab.reload)
                    Button("Open Launcher") { openWindow(id: "launcher") }
                    Button("Close Window", action: close)
                }
                .glassBackgroundEffect()
            } else {
                terminal
                    .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                        FixtureTerminalTitle()
                            .frame(maxWidth: min(lab.size.width, 720))
                            .padding(.bottom, 20)
                    }
            }
        }
        .frame(width: lab.size.width, height: lab.size.height)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            VStack(spacing: 8) {
                if lab.arrangement == .bottom && lab.session != .recovery {
                    inputGroup
                }
                // Keep lab navigation outside the evaluated terminal surface.
                Button("Lab Controls", systemImage: "slider.horizontal.3") { openWindow(id: "controls") }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Session", role: .destructive, action: lab.end)
        } message: {
            Text("This stops the terminal and its attached dev servers and closes its session-owned previews. Close the window to keep them running.")
        }
        .sheet(isPresented: $showReport) { FixtureBugReport() }
        .onAppear {
            lab.terminalVisible = true
        }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--controls") { openWindow(id: "controls") }
            if let index = arguments.firstIndex(of: "--voice"), arguments.indices.contains(index + 1),
               let preset = VoiceScenario(rawValue: arguments[index + 1]) {
                lab.stageVoice(preset)
            }
            if let index = arguments.firstIndex(of: "--popover"), arguments.indices.contains(index + 1) {
                previewsExpanded = arguments[index + 1] == "frontends" && lab.arrangement == .split
                showActions = arguments[index + 1] == "actions" || previewsExpanded
                showFrontends = arguments[index + 1] == "frontends" && !previewsExpanded
            }
        }
        .onDisappear { lab.closeTerminal() }
        .onChange(of: voice.targetID) { old, new in
            if old == LabModel.terminalID && new == nil { lab.clearVoiceFixture() }
        }
        .onChange(of: lab.arrangement) { _, _ in
            showActions = false
            showFrontends = false
        }
    }

    private var terminal: some View {
        ZStack(alignment: .top) {
            if lab.session == .invalid {
                ContentUnavailableView(
                    "Invalid Terminal URL",
                    systemImage: "exclamationmark.triangle",
                    description: Text("SlopZooka could not open the terminal surface.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassBackgroundEffect()
            } else {
                FixtureTerminalSurface()
            }
            connectionNotice
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 16) {
                    if lab.arrangement == .split { actionsButton }
                    else { frontendsButton }
                    if let status = lab.session.status {
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(lab.session == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        if lab.arrangement != .split { actionsButton }
                        switch lab.arrangement {
                        case .split:
                            glassIcon("Interrupt", "hand.raised.fill", action: lab.interrupt)
                                .disabled(!lab.session.acceptsControls)
                                .accessibilityHint("Send Escape to the terminal")
                            stopButton
                        case .current:
                            keyboardButton
                            interruptButton
                            stopButton
                        case .grouped: inputGroup
                        case .overflow: interruptButton
                        case .bottom: EmptyView()
                        }
                    }
                }
                if lab.showDetails { details }
            }
            .padding(14)
        }
        .modifier(TerminalVoiceOverlay(id: LabModel.terminalID, isAvailable: lab.session.acceptsControls,
                                       canRename: lab.canRename, mode: lab.dictation == .hold ? .terminal : .coordinator))
        .overlay(alignment: .bottomTrailing) {
            if lab.dictation == .review { ReviewDictationBar() }
        }
        .overlay {
            if lab.unread {
                RoundedRectangle(cornerRadius: 18).strokeBorder(.orange, lineWidth: 5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if lab.unread {
                Label("Unread notification", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { lab.unread = false })
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if lab.session == .disconnected || lab.session == .connecting {
            VStack(spacing: 10) {
                Text(lab.session == .disconnected ? "Lost companion connection." : "Connecting to your Mac…")
                    .font(.headline)
                if lab.session == .disconnected {
                    Text("Reopen SlopZooka on your Mac.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var keyboardButton: some View {
        glassIcon("Show terminal keyboard", "keyboard") { lab.focusedKeyboard = true }
            .disabled(!lab.session.acceptsControls)
    }

    private var interruptButton: some View {
        Button(action: lab.interrupt) {
            Label("Interrupt", systemImage: "escape")
                .font(.body.weight(.medium))
                .padding(.horizontal, 20)
                .frame(minHeight: 60)
        }
        .buttonStyle(TerminalGlassControlStyle(shape: Capsule()))
        .disabled(!lab.session.acceptsControls)
        .accessibilityHint("Send Escape to the terminal")
    }

    private var stopButton: some View {
        glassIcon("End session", "stop.fill", role: .destructive) { confirmEnd = true }
            .accessibilityHint("Confirm before stopping the terminal and its attached dev servers")
    }

    private var inputGroup: some View {
        HStack(spacing: 0) {
            Button {
                lab.focusedKeyboard = true
            } label: {
                Label("Show terminal keyboard", systemImage: "keyboard")
                    .labelStyle(.iconOnly).frame(width: 60, height: 60)
            }
            Divider().frame(height: 26).accessibilityHidden(true)
            Button(action: lab.interrupt) {
                Label("Interrupt", systemImage: "escape")
                    .padding(.horizontal, 16).frame(minHeight: 60)
            }
            .accessibilityHint("Send Escape to the terminal")
        }
        .buttonStyle(.borderless)
        .glassBackgroundEffect(in: Capsule())
        .disabled(!lab.session.acceptsControls)
    }

    private var actionsButton: some View {
        glassIcon("Session actions", "ellipsis") { showActions.toggle() }
            .popover(isPresented: $showActions, arrowEdge: .top) {
                actionMenu.onDisappear {
                    let action = afterActions
                    afterActions = nil
                    previewsExpanded = false
                    action?()
                }
            }
    }

    private var actionMenu: some View {
        @Bindable var lab = lab
        return ScrollView {
            VStack(spacing: 8) {
                TerminalZoomControls(steps: $lab.zoom, defaultSteps: TerminalZoom.initialDefaultSteps)
                Divider()
                if lab.arrangement == .split {
                    previewsMenuSection
                    Divider()
                    keyboardMenuRow
                    launcherMenuRows
                } else if lab.arrangement == .overflow {
                    keyboardMenuRow
                    Divider()
                }
                menuRow("New Shell", "terminal", action: lab.openShell)
                menuRow("Reload Content", "arrow.clockwise", action: lab.reload)
                if lab.arrangement != .split { launcherMenuRows }
                menuRow("Session Details", "info.circle") {
                    lab.showDetails.toggle()
                    lab.detailsExpanded = lab.showDetails
                }
                menuRow("Report a Bug", "ladybug") { showReport = true }
                Divider()
                menuRow("Close Window", "xmark", action: close)
                if lab.arrangement != .current && lab.arrangement != .split {
                    menuRow("End Session", "stop.fill", role: .destructive) { confirmEnd = true }
                }
            }
            .padding(12)
        }
        .frame(width: 400)
        .frame(maxHeight: 690)
        .defaultScrollAnchor(.top, for: .alignment)
    }

    private var keyboardMenuRow: some View {
        menuRow("Show Terminal Keyboard", "keyboard") { lab.focusedKeyboard = true }
            .disabled(!lab.session.acceptsControls)
    }

    private var launcherMenuRows: some View {
        Group {
            menuRow("Ask SlopZooka", "mic.badge.plus") { openWindow(id: "ask") }
            menuRow("Open Launcher", "square.grid.2x2") { openWindow(id: "launcher") }
        }
    }

    private var previewsMenuSection: some View {
        DisclosureGroup(isExpanded: $previewsExpanded) {
            FixtureFrontends { title in
                dismissActions { openPreview(title) }
            }
            .padding(.top, 8)
        } label: {
            Label("Previews", systemImage: "globe")
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
    }

    private var details: some View {
        @Bindable var lab = lab
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if lab.session == .failed {
                    Text("The terminal content could not be loaded.").font(.footnote).foregroundStyle(.red)
                }
                DisclosureGroup(isExpanded: $lab.detailsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        detail("Session", lab.payload.title)
                        detail("Connected Host", "slopzooka-mac.local")
                        detail("Terminal URL", "http://slopzooka-mac.local:7777/terminal?sessionId=fixture")
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Debug Log").font(.headline)
                            Text("terminal.surface.attached  session=fixture").font(.caption2)
                            Text(lab.lastAction).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Session Details", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 520)
        .frame(maxHeight: lab.detailsExpanded ? 410 : 82)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private var frontendsButton: some View {
        let count = lab.frontends == .empty ? 0 : 2
        return Button { showFrontends.toggle() } label: {
            Image(systemName: "globe").font(.system(size: 26, weight: .medium)).frame(width: 72, height: 72)
        }
        .buttonStyle(TerminalGlassControlStyle(shape: Circle()))
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color("AccentHighlight"), in: Capsule())
                    .compositingGroup()
                    .clipShape(Capsule())
                    .offset(x: -2, y: 2)
                    .offset(z: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Show worktree frontends")
        .accessibilityValue(lab.frontends == .warning ? "\(count) frontends, discovery notice" : "\(count) frontends")
        .popover(isPresented: $showFrontends, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Web frontends", systemImage: "globe").font(.headline)
                    FixtureFrontends { title in
                        showFrontends = false
                        openPreview(title)
                    }
                }
                .padding(16)
            }
            .frame(width: 420)
            .frame(maxHeight: 420)
            .defaultScrollAnchor(.top, for: .alignment)
        }
    }

    private func openPreview(_ title: String) {
        lab.lastAction = "Opened \(title) preview"
        lab.previewTitle = title
        openWindow(id: "preview")
    }

    private func glassIcon(_ label: String, _ symbol: String, role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .frame(width: 60, height: 60)
        }
        .buttonStyle(TerminalGlassControlStyle(shape: Circle()))
        .accessibilityLabel(label)
    }

    private func menuRow(_ title: String, _ symbol: String, role: ButtonRole? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(role: role) {
            dismissActions(then: action)
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }

    private func dismissActions(then action: @escaping () -> Void) {
        afterActions = action
        showActions = false
    }

    private func close() {
        openWindow(id: "controls")
        dismissWindow(id: "terminal")
    }
}
