import SwiftUI

struct TerminalWindowView: View {
    let sessionID: String?

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var debugLog = AppDebugLog.shared
    @StateObject private var speechCapture = SpeechCaptureController()
    @State private var loadState: TerminalLoadState = .idle
    @State private var isUtilitiesExpanded = false
    @State private var isSessionDetailsExpanded = false
    @State private var isSpeechPanelExpanded = false
    @State private var isPreviewPanelExpanded = false
    @State private var isSubmittingSpeech = false
    @State private var speechSubmitError: String?
    @State private var speechOrbPulse = false
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
            speechCapture.stopListening()
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
                CompanionWebView(
                    url: url,
                    loadState: $loadState,
                    focusRequestToken: focusRequestToken
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
                        isPreviewPanelExpanded.toggle()
                    } label: {
                        Image(systemName: "globe")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())

                    Button {
                        if isSpeechPanelExpanded {
                            speechCapture.stopListening()
                            isSpeechPanelExpanded = false
                        } else {
                            isSpeechPanelExpanded = true
                            Task {
                                await speechCapture.startListening()
                            }
                        }
                    } label: {
                        Image(systemName: speechCapture.isListening ? "mic.circle.fill" : "mic.circle")
                            .font(.title3)
                            .foregroundStyle(speechCapture.isListening ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())

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
                        Image(
                            systemName: isUtilitiesExpanded
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                        )
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

                if isSpeechPanelExpanded {
                    speechPanel(payloadID: payload.id)
                        .frame(maxWidth: 420, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isPreviewPanelExpanded {
                    FrontendPanel(baseURL: payload.url)
                        .frame(maxWidth: 420, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isUtilitiesExpanded {
                    terminalUtilitiesSection(payload: payload)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(14)
        }
        .onAppear {
            slzLog("terminal scene appeared \(payload.id)")
            appModel.markTerminalPresented(id: payload.id, isPresented: true)
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                speechOrbPulse = true
            }
        }
        .onChange(of: loadState) { _, newLoadState in
            appModel.updateTerminalLoadState(id: payload.id, loadState: newLoadState)
        }
    }

    private func closeWindow(payloadID: String) {
        appModel.markTerminalPresented(id: payloadID, isPresented: false)
        dismissWindow(id: "terminal", value: payloadID)
    }

    private func terminalUtilitiesSection(payload: TerminalWindowPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let message) = loadState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("New Shell") { Task { await newShell(payload: payload) } }
                Button("End Session", role: .destructive) { Task { await endSession(payload: payload) } }
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

    private func speechPanel(payloadID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(speechCapture.isListening ? .red.opacity(0.9) : .secondary.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .scaleEffect(speechCapture.isListening && speechOrbPulse ? 1.18 : 0.92)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice Input")
                        .font(.subheadline.weight(.semibold))

                    Text(speechCapture.statusText)
                        .font(.caption)
                        .foregroundStyle(speechCapture.isListening ? .red : .secondary)
                }

                Spacer()
            }

            ScrollView {
                Text(speechCapture.transcript.isEmpty ? speechPlaceholderText : speechCapture.transcript)
                    .font(.body)
                    .foregroundStyle(speechCapture.transcript.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 88, maxHeight: 148)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                Button("Close") {
                    speechCapture.stopListening()
                    isSpeechPanelExpanded = false
                }
                .buttonStyle(.bordered)

                if speechCapture.isListening {
                    Button("Stop") {
                        speechCapture.stopListening()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        Task {
                            await speechCapture.startListening()
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Button("Submit") {
                    Task {
                        await submitSpeechTranscript(payloadID: payloadID)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submissionTranscript.isEmpty || !canSubmitSpeech || isSubmittingSpeech)
            }

            if let speechSubmitError {
                Text(speechSubmitError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
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
        case .ended(let message):
            return message
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
        case .loading, .idle, .loaded, .ended:
            return AnyShapeStyle(.secondary)
        }
    }

    private var submissionTranscript: String {
        let trimmed = speechCapture.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    private var canSubmitSpeech: Bool {
        if case .loading = loadState {
            return false
        }

        return payload != nil
    }

    private var speechPlaceholderText: String {
        if speechCapture.isListening {
            return "Listening… speak naturally, then stop or submit."
        }

        return "Tap Start and speak. Submit sends the transcript and Enter to the active PTY."
    }

    private func syncScenePhase(_ phase: ScenePhase, sessionID: String) {
        switch phase {
        case .active:
            appModel.markTerminalPresented(id: sessionID, isPresented: true)
            appModel.markTerminalFocused(id: sessionID, isFocused: true)
            focusRequestToken += 1
            slzLog("terminal scene active \(sessionID)")
        case .inactive:
            speechCapture.stopListening()
            appModel.markTerminalFocused(id: sessionID, isFocused: false)
            slzLog("terminal scene inactive \(sessionID)")
        case .background:
            speechCapture.stopListening()
            appModel.markTerminalPresented(id: sessionID, isPresented: false)
            appModel.markTerminalFocused(id: sessionID, isFocused: false)
            slzLog("terminal scene background \(sessionID)")
        @unknown default:
            break
        }
    }

    private func submitSpeechTranscript(payloadID: String) async {
        let text = submissionTranscript
        guard !text.isEmpty else {
            return
        }

        guard let payload,
            let inputURL = surfaceInputURL(for: payload)
        else {
            speechSubmitError = "Terminal input route is unavailable."
            slzLog("terminal speech submit missing route \(payloadID)")
            return
        }

        speechCapture.stopListening()
        speechSubmitError = nil
        isSubmittingSpeech = true

        defer {
            isSubmittingSpeech = false
        }

        do {
            try await submitSurfaceInput(text: text, to: inputURL)

            speechCapture.clearTranscript()
            isSpeechPanelExpanded = false
            focusRequestToken += 1
            slzLog("terminal speech submitted \(payloadID)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            speechSubmitError = message
            slzLog("terminal speech submit failed \(payloadID): \(message)")
        }
    }

    private func newShell(payload: TerminalWindowPayload) async {
        guard let base = payload.url else { return }
        do {
            let result = try await CompanionAPI.request(
                CreatedSessionResponse.self, base: base,
                path: "/api/workspaces/\(payload.workspaceId)/sessions", method: "POST",
                body: JSONSerialization.data(withJSONObject: ["sessionId": UUID().uuidString, "profile": NSNull()]))
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
            components.queryItems = [URLQueryItem(name: "sessionId", value: result.session.id)]
            guard let url = components.url else { return }
            appModel.registerTerminal(
                TerminalWindowPayload(
                    id: result.session.id, workspaceId: payload.workspaceId, title: "Terminal",
                    urlString: url.absoluteString))
            openWindow(id: "terminal", value: result.session.id)
        } catch { loadState = .failed(error.localizedDescription) }
    }

    private func endSession(payload: TerminalWindowPayload) async {
        guard let base = payload.url else { return }
        do {
            _ = try await CompanionAPI.request(
                APIAcknowledgement.self, base: base, path: "/api/sessions/\(payload.id)", method: "DELETE")
            closeWindow(payloadID: payload.id)
        } catch { loadState = .failed(error.localizedDescription) }
    }

    private func surfaceInputURL(for payload: TerminalWindowPayload) -> URL? {
        guard let baseURL = payload.url,
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        components.path = "/api/sessions/\(payload.id)/input"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func submitSurfaceInput(text: String, to inputURL: URL) async throws {
        // Retrying a lost response uses the same command ID; the host deduplicates it.
        let body = try JSONSerialization.data(withJSONObject: [
            "commandId": UUID().uuidString, "text": text, "sendReturn": true,
        ])
        for attempt in 0..<2 {
            do {
                _ = try await CompanionAPI.request(
                    APIAcknowledgement.self, base: inputURL, path: inputURL.path, method: "POST", body: body)
                return
            } catch let error as URLError
                where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code)
            {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
