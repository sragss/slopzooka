import SwiftUI

struct TerminalWindowView: View {
    let sessionID: String?

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var debugLog = AppDebugLog.shared
    @State private var loadState: TerminalLoadState = .idle
    @State private var isUtilitiesExpanded = false
    @State private var isSessionDetailsExpanded = false
    @State private var focusRequestToken = 0

    var body: some View {
        Group {
            if let payload {
                terminalMode(payload: payload)
            } else {
                ContentUnavailableView(
                    "Session Unavailable",
                    systemImage: "rectangle.slash",
                    description: Text("This terminal session is no longer available.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            slzLog("TerminalWindowView appeared \(sessionID ?? "nil")")
            if let sessionID {
                appModel.markTerminalPresented(id: sessionID, isPresented: true)
                syncScenePhase(scenePhase, sessionID: sessionID)
            }
        }
        .onDisappear {
            if let sessionID {
                appModel.markTerminalPresented(id: sessionID, isPresented: false)
                appModel.markTerminalFocused(id: sessionID, isFocused: false)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard let sessionID else {
                return
            }

            syncScenePhase(newPhase, sessionID: sessionID)
        }
    }

    private var payload: TerminalWindowPayload? {
        guard let sessionID else {
            return nil
        }

        return appModel.terminalPayload(for: sessionID)
    }

    private func terminalMode(payload: TerminalWindowPayload) -> some View {
        ZStack(alignment: .top) {
            if let url = payload.url {
                CompanionWebView(url: url, loadState: $loadState, focusRequestToken: focusRequestToken)
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

                    Button {
                        openWindow(id: "launcher")
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())

                    Button {
                        isUtilitiesExpanded.toggle()
                        if !isUtilitiesExpanded {
                            isSessionDetailsExpanded = false
                        }
                    } label: {
                        Image(systemName: isUtilitiesExpanded ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())

                    Button {
                        closeWindow(payloadID: payload.id)
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
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(14)
        }
        .onAppear {
            slzLog("terminal scene appeared \(payload.id)")
            appModel.markTerminalPresented(id: payload.id, isPresented: true)
        }
        .onChange(of: loadState) { _, newLoadState in
            appModel.updateTerminalLoadState(id: payload.id, loadState: newLoadState)
        }
    }

    private func closeWindow(payloadID: String) {
        appModel.removeTerminal(id: payloadID)
        dismissWindow(id: "terminal", value: payloadID)
    }

    private func terminalUtilitiesSection(payload: TerminalWindowPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .failed(message) = loadState {
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

    private var terminalStatusText: String? {
        switch loadState {
        case .idle, .loaded:
            return nil
        case .loading:
            return "Loading"
        case .failed:
            return "Failed"
        }
    }

    private var terminalStatusColor: AnyShapeStyle {
        switch loadState {
        case .failed:
            return AnyShapeStyle(.red)
        case .loading, .idle, .loaded:
            return AnyShapeStyle(.secondary)
        }
    }

    private func syncScenePhase(_ phase: ScenePhase, sessionID: String) {
        switch phase {
        case .active:
            appModel.markTerminalPresented(id: sessionID, isPresented: true)
            appModel.markTerminalFocused(id: sessionID, isFocused: true)
            focusRequestToken += 1
            slzLog("terminal scene active \(sessionID)")
        case .inactive:
            appModel.markTerminalFocused(id: sessionID, isFocused: false)
            slzLog("terminal scene inactive \(sessionID)")
        case .background:
            appModel.markTerminalPresented(id: sessionID, isPresented: false)
            appModel.markTerminalFocused(id: sessionID, isFocused: false)
            slzLog("terminal scene background \(sessionID)")
        @unknown default:
            break
        }
    }
}
