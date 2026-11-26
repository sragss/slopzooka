import Foundation
import Observation

enum Arrangement: String, CaseIterable, Identifiable {
    case split = "Menu left, controls right"
    case current = "Original toolbar"
    case grouped = "Grouped input"
    case overflow = "Quiet toolbar"
    case bottom = "Bottom input dock"
    var id: Self { self }

    var summary: String {
        switch self {
        case .split: "Previews and keyboard are in the left menu. Interrupt and Stop are full-size circles on the right."
        case .current: "Session actions, keyboard, Interrupt, and End across the top."
        case .grouped: "Keyboard and Interrupt share a capsule. End moves into Session actions."
        case .overflow: "Labeled Interrupt stays visible. Keyboard and End move into Session actions."
        case .bottom: "Keyboard and Interrupt move to a bottom ornament. Session actions stay above."
        }
    }
}

enum DictationTreatment: String, CaseIterable, Identifiable {
    case hold = "Hold and release"
    case review = "Tap to review"
    var id: Self { self }
}

enum SessionState: String, CaseIterable, Identifiable {
    case connected = "Connected"
    case readOnly = "Read only"
    case connecting = "Connecting"
    case disconnected = "Disconnected"
    case failed = "Load failed"
    case ended = "Session ended"
    case recovery = "Reconnect window"
    case invalid = "Invalid terminal URL"
    var id: Self { self }

    // The WebView is still loaded while another client owns keyboard input.
    var acceptsControls: Bool { self == .connected || self == .readOnly }
    var status: String? {
        switch self {
        case .failed: "Failed"
        case .ended: "Session ended"
        default: nil
        }
    }
}

enum FrontendFixture: String, CaseIterable, Identifiable {
    case available = "Two available"
    case empty = "Empty"
    case starting = "Starting and stopped"
    case restricted = "Direct restriction"
    case warning = "Discovery warning"
    var id: Self { self }
}

enum WindowSize: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case standard = "Production"
    case expanded = "Expanded"
    var id: Self { self }

    var width: CGFloat {
        switch self {
        case .compact: 680
        case .standard: 1280
        case .expanded: 1480
        }
    }
    var height: CGFloat {
        switch self {
        case .compact: 510
        case .standard: 832
        case .expanded: 920
        }
    }
}

enum VoiceScenario: String, CaseIterable, Identifiable {
    case idle = "Idle"
    case preparing = "Preparing microphone"
    case listening = "Listening, empty"
    case partial = "Partial transcript"
    case long = "Long transcript"
    case countdown = "Release countdown"
    case denied = "Microphone denied"
    case retry = "Delivery error and Retry"
    var id: Self { self }
}

/// This shape supplies the production title ornament with fixture data.
struct TerminalWindowPayload {
    let id = LabModel.terminalID
    var projectName: String? = "slopzooka"
    var workspaceName: String? = "terminal-controls"
    var title = "Codex"
}

struct FixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
final class LabModel {
    nonisolated static let terminalID = "terminal-fixture"
    nonisolated static let reviewID = "review-fixture"
    var arrangement: Arrangement = .split
    var dictation: DictationTreatment = .hold
    var session: SessionState = .connected
    var frontends: FrontendFixture = .available
    var previewTitle = ""
    var size: WindowSize = .standard
    var unread = false
    var zoom = TerminalZoom.initialDefaultSteps
    var payload = TerminalWindowPayload()
    var showDetails = false
    var detailsExpanded = false
    var focusedKeyboard = false
    var terminalVisible = true
    var isShell = false
    var output: [String] = []
    var lastAction = "Ready"
    private(set) var reviewReady = false
    private(set) var reviewDeliveryFailed = false
    private var rejectNextDelivery = false
    private var reloadTask: Task<Void, Never>?
    let capture = FixtureSpeechCapture()

    @ObservationIgnored lazy var voice = TerminalVoiceController(
        capture: capture,
        isAvailable: { [weak self] _, mode in
            guard let self else { return false }
            return self.terminalVisible && (mode == .rename ? self.canRename : self.session.acceptsControls)
        },
        rename: { [weak self] _, name, target in
            switch target {
            case .workspace: self?.payload.workspaceName = name
            case .window: self?.payload.title = name
            }
            self?.lastAction = "Saved \(target.rawValue) name"
        },
        deliver: { [weak self] command in
            try await Task.sleep(for: .milliseconds(180))
            try self?.deliver(command.text, destination: command.destination)
        }
    )

    var canRename: Bool { session != .recovery && session != .invalid }

    func selectSession(_ state: SessionState) {
        reloadTask?.cancel()
        updateSession(state)
    }

    private func updateSession(_ state: SessionState) {
        session = state
        if !state.acceptsControls {
            focusedKeyboard = false
            if voice.targetID == Self.reviewID {
                reviewReady = true
                voice.targetUnavailable(Self.reviewID)
            }
            if voice.mode != .rename || !canRename {
                voice.targetUnavailable(Self.terminalID)
            }
        }
    }

    func reload() {
        reloadTask?.cancel()
        lastAction = "Reload Content"
        updateSession(.connecting)
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.updateSession(.connected)
        }
    }

    func openShell() {
        guard session.acceptsControls else {
            selectSession(.failed)
            lastAction = "New Shell failed"
            return
        }
        isShell = true
        payload.title = "Shell"
        output.removeAll()
        lastAction = "Opened a fixture shell"
    }

    func submitKeyboard(_ text: String) {
        guard session == .connected, !text.isEmpty else { return }
        append("> " + text)
        lastAction = "Sent keyboard input"
    }

    func interrupt() {
        guard session.acceptsControls else { return }
        lastAction = session == .readOnly ? "Escape ignored while read only" : "Sent Escape"
        if session == .connected { append("⎋ Interrupted") }
    }

    func end() {
        selectSession(.ended)
        append("[process exited]")
        lastAction = "Ended fixture session"
    }

    func stopVoice() {
        voice.stop()
        clearVoiceFixture()
    }

    func clearVoiceFixture() {
        capture.onFixtureReady = nil
        capture.fixture = .idle
        rejectNextDelivery = false
        reviewReady = false
        reviewDeliveryFailed = false
    }

    func selectDictation(_ treatment: DictationTreatment) {
        stopVoice()
        dictation = treatment
    }

    func startReview() {
        guard session.acceptsControls else { return }
        reviewReady = false
        reviewDeliveryFailed = false
        voice.activateDraft(Self.reviewID) { _ in }
    }

    func sendReview() {
        guard session.acceptsControls, reviewReady, voice.targetID == Self.reviewID, voice.canSend else { return }
        do {
            try deliver(voice.transcript)
            stopVoice()
        } catch {
            reviewDeliveryFailed = true
        }
    }

    func pauseForReview() {
        guard voice.targetID == Self.reviewID else { return }
        voice.pause()
        reviewReady = true
    }

    func resumeReview() {
        guard voice.targetID == Self.reviewID, session.acceptsControls else { return }
        reviewReady = false
        voice.resume()
    }

    func stageVoice(_ scenario: VoiceScenario) {
        stopVoice()
        guard scenario != .idle else { return }
        if !session.acceptsControls { selectSession(.connected) }
        capture.fixture = scenario
        rejectNextDelivery = scenario == .retry
        if scenario == .countdown || scenario == .retry {
            capture.onFixtureReady = { [weak self] in
                guard let self else { return }
                if self.dictation == .review {
                    self.pauseForReview()
                    if scenario == .retry { self.sendReview() }
                } else {
                    self.voice.endTerminalHold(Self.terminalID)
                }
            }
        }
        if dictation == .review { startReview() }
        else { voice.beginTerminalHold(Self.terminalID) }
    }

    func closeTerminal() {
        stopVoice()
        focusedKeyboard = false
        terminalVisible = false
        lastAction = "Closed window"
    }

    func reset() {
        stopVoice()
        selectSession(.connected)
        frontends = .available
        unread = false
        zoom = TerminalZoom.initialDefaultSteps
        payload = TerminalWindowPayload()
        showDetails = false
        detailsExpanded = false
        focusedKeyboard = false
        isShell = false
        output.removeAll()
        lastAction = "Ready"
    }

    private func deliver(_ text: String, destination: TerminalVoiceCommand.Destination = .terminal) throws {
        guard session.acceptsControls else { throw FixtureError(message: "Terminal is not connected.") }
        if rejectNextDelivery {
            rejectNextDelivery = false
            throw FixtureError(message: "The Mac didn’t acknowledge delivery.")
        }
        append(destination == .terminal ? "> " + text : "Ask SlopZooka: " + text)
        lastAction = destination == .terminal ? "Delivered dictation" : "Sent coordinator request"
    }

    private func append(_ text: String) {
        output.append(text)
        if output.count > 40 { output.removeFirst() }
    }
}

/// Plays scripted recognition through the same callbacks used by the real voice controller.
@MainActor
final class FixtureSpeechCapture: SpeechCapturing {
    static let partial = "Run the terminal keyboard checks"
    static let full = "Run the terminal keyboard checks and tell me which cases still need a headset."
    static let long = [
        full,
        "Open the actions popover and check the zoom reset, the spacing around each target, and whether the whole row highlights when I look at it.",
        "Then shrink the window, start dictating again, and check that I can scroll back through the earlier lines before sending the request.",
    ].joined(separator: "\n\n")

    private(set) var state: SpeechCaptureState = .idle
    private(set) var transcript = ""
    private(set) var audioLevels = [0.30, 0.64, 0.91, 0.48, 0.24]
    var onUpdate: (() -> Void)?
    var onAudioLevels: (() -> Void)?
    var onFinished: (() -> Void)?
    var fixture: VoiceScenario = .idle
    private var playTask: Task<Void, Never>?
    var onFixtureReady: (() -> Void)?

    func startListening(finishOnPause: Bool) async {
        let scenario = fixture
        fixture = .idle
        setState(.preparing)
        if scenario == .preparing { return }
        if scenario == .denied {
            setState(.unavailable("Microphone permission was denied."))
            return
        }

        if scenario == .idle {
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        setState(.listening)
        onAudioLevels?()
        switch scenario {
        case .partial: setText(Self.partial)
        case .long: setText(Self.long)
        case .countdown, .retry: setText(Self.full)
        case .idle:
            playTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.setText(finishOnPause ? "review" : Self.partial)
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                self.setText(finishOnPause ? "review notes" : Self.full)
                if finishOnPause { self.finishListening() }
            }
        default: break
        }
        let ready = onFixtureReady
        onFixtureReady = nil
        ready?()
    }

    func finishListening() {
        playTask?.cancel()
        setState(.finishing)
        playTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            if self.transcript == Self.partial { self.setText(Self.full) }
            self.setState(.idle)
            self.onFinished?()
        }
    }

    func stopListening() {
        playTask?.cancel()
        playTask = nil
        setState(.idle)
    }

    func clearTranscript() { transcript = "" }

    private func setState(_ next: SpeechCaptureState) {
        state = next
        onUpdate?()
    }

    private func setText(_ next: String) {
        transcript = next
        audioLevels.reverse()
        onAudioLevels?()
        onUpdate?()
    }
}
