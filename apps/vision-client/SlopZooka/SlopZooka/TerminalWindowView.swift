import SwiftUI

struct TerminalWindowView: View {
    let sessionID: String?

    @EnvironmentObject private var windows: WindowGateway
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var debugLog = AppDebugLog.shared
    @State private var loadState: TerminalLoadState = .idle
    @State private var isUtilitiesExpanded = false
    @State private var confirmEndSession = false
    @State private var isSessionDetailsExpanded = false
    @State private var isActionsPresented = false
    @State private var focusRequestToken = 0
    @State private var interruptRequestToken = 0
    @AppStorage(TerminalZoom.defaultStepsKey) private var defaultTerminalZoomSteps = TerminalZoom.initialDefaultSteps
    @SceneStorage("terminalZoomSteps") private var terminalZoomSteps: Int?

    private var zoomSteps: Binding<Int> {
        Binding(
            get: { TerminalZoom.resolvedSteps(scene: terminalZoomSteps, defaultSteps: defaultTerminalZoomSteps) },
            set: { terminalZoomSteps = $0 }
        )
    }

    private var defaultZoomSteps: Int {
        TerminalZoom.resolvedSteps(scene: nil, defaultSteps: defaultTerminalZoomSteps)
    }

    var body: some View {
        Group {
            if let payload {
                terminalMode(payload: payload)
            } else {
                WindowRecoveryView(id: sessionID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncScenePhase(scenePhase) }
        .onChange(of: scenePhase) { _, newPhase in
            syncScenePhase(newPhase)
        }
    }

    private var payload: TerminalWindowPayload? {
        guard let sessionID else {
            return nil
        }

        return windows.terminalPayload(for: sessionID)
    }

    private func terminalMode(payload: TerminalWindowPayload) -> some View {
        ZStack(alignment: .top) {
            if let url = payload.url {
                CompanionWebView(
                    url: url,
                    reloadToken: windows.reloadToken(for: payload.id),
                    loadState: $loadState,
                    focusRequestToken: focusRequestToken,
                    interruptRequestToken: interruptRequestToken,
                    zoom: TerminalZoom.scale(steps: zoomSteps.wrappedValue)
                )
                .id(payload.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ContentUnavailableView(
                    "Invalid Terminal URL",
                    systemImage: "exclamationmark.triangle",
                    description: Text("SlopZooka could not open the terminal surface.")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            }

            if let notice = terminalConnectionNotice {
                VStack(spacing: 10) {
                    Text(notice.title).font(.headline)
                    if let guidance = notice.guidance {
                        Text(guidance).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let statusText = terminalStatusText {
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(terminalStatusColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    WorkspaceFrontendButton(baseURL: payload.url, workspaceId: payload.workspaceId)

                    Button {
                        isActionsPresented.toggle()
                    } label: {
                        Image(systemName: "ellipsis").font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .contentShape(.hoverEffect, Circle())
                    }
                    .buttonStyle(.plain)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Session actions")
                    .popover(isPresented: $isActionsPresented, arrowEdge: .top) {
                        terminalActions(payload: payload)
                    }

                    Button {
                        interruptRequestToken += 1
                    } label: {
                        Label("Interrupt", systemImage: "escape")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canSubmitSpeech)
                    .help("Send Escape to the terminal")

                    Button {
                        windows.close(id: payload.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
                }

                if isUtilitiesExpanded {
                    terminalUtilitiesSection(payload: payload)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(14)
        }
        .modifier(TerminalVoiceOverlay(id: payload.id, isAvailable: canSubmitSpeech,
            onSent: { focusRequestToken += 1 }))
        .confirmationDialog("End this session?", isPresented: $confirmEndSession, titleVisibility: .visible) {
            Button("End Session", role: .destructive) { Task { await endSession(payload: payload) } }
        } message: {
            Text("This stops the terminal and its attached dev servers. Close the window to keep them running.")
        }
        .onAppear {
            slzLog("terminal scene appeared \(payload.id)")
        }
        .onChange(of: loadState) { _, newLoadState in
            windows.updateTerminalLoadState(id: payload.id, loadState: newLoadState)
        }
    }

    private func terminalActions(payload: TerminalWindowPayload) -> some View {
        VStack(spacing: 0) {
            TerminalZoomControls(steps: zoomSteps, defaultSteps: defaultZoomSteps)
            Divider()
            Button("New Shell", systemImage: "terminal") {
                isActionsPresented = false
                Task { await newShell(payload: payload) }
            }
            Button("Reload Content", systemImage: "arrow.clockwise") {
                isActionsPresented = false
                windows.reload(id: payload.id)
            }
            Button("Open Launcher", systemImage: "square.grid.2x2") {
                isActionsPresented = false
                windows.openLauncher()
            }
            Button("Session Details", systemImage: "info.circle") {
                isActionsPresented = false
                isUtilitiesExpanded.toggle()
                isSessionDetailsExpanded = isUtilitiesExpanded
            }
            Divider()
            Button("End Session…", role: .destructive) {
                isActionsPresented = false
                confirmEndSession = true
            }
        }
        .buttonStyle(TerminalMenuButtonStyle())
        .frame(width: 360)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func terminalUtilitiesSection(payload: TerminalWindowPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let message) = loadState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            DisclosureGroup(isExpanded: $isSessionDetailsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    labeledDetailRow(label: "Session", value: payload.title)

                    if let host = payload.url?.host {
                        labeledDetailRow(label: "Connected Host", value: host)
                    }

                    labeledDetailRow(label: "Terminal URL", value: payload.urlString)

                    debugLogView
                }
                .padding(.top, 8)
            } label: {
                Label("Session Details", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func labeledDetailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var terminalConnectionNotice: (title: String, guidance: String?)? {
        switch loadState {
        case .disconnected:
            return ("Lost companion connection.", "Reopen SlopZooka on your Mac.")
        case .idle, .loading:
            return ("Connecting to your Mac…", nil)
        case .loaded, .failed, .ended:
            return nil
        }
    }

    private var terminalStatusText: String? {
        switch loadState {
        case .ended(let message):
            return message
        case .idle, .loaded, .loading, .disconnected:
            return nil
        case .failed:
            return "Failed"
        }
    }

    private var terminalStatusColor: AnyShapeStyle {
        switch loadState {
        case .failed:
            return AnyShapeStyle(.red)
        case .loading, .disconnected, .idle, .loaded, .ended:
            return AnyShapeStyle(.secondary)
        }
    }

    private var canSubmitSpeech: Bool {
        if case .loaded = loadState { return payload != nil && scenePhase == .active }
        return false
    }

    private func syncScenePhase(_ phase: ScenePhase) {
        if phase == .active { focusRequestToken += 1 }
    }

    private func newShell(payload: TerminalWindowPayload) async {
        do { try await windows.newShell(for: payload.id) }
        catch { loadState = .failed(error.localizedDescription) }
    }

    private func endSession(payload: TerminalWindowPayload) async {
        do { try await windows.endSession(id: payload.id) }
        catch { loadState = .failed(error.localizedDescription) }
    }
}
