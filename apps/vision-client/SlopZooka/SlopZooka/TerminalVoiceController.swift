import Combine
import Foundation

enum SpeechCaptureState: Equatable {
    case idle, preparing, listening, finishing
    case unavailable(String), failed(String)
}

/// One microphone owner, independent of window rendering and the recognition backend.
@MainActor
protocol SpeechCapturing: AnyObject {
    var state: SpeechCaptureState { get }
    var transcript: String { get }
    var audioLevels: [Double] { get }
    var onUpdate: (() -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func startListening(finishOnPause: Bool) async
    func finishListening()
    func stopListening()
    func clearTranscript()
}

struct TerminalVoiceCommand: Equatable {
    let targetID: String
    let commandID: String
    let text: String
}

struct TerminalVoiceSubmission: Equatable {
    let targetID: String
    let commandID: String
}

enum WindowName {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

/// Owns transient voice intent only. WindowGateway resolves IDs and delivers input.
/// Hold-to-talk, naming, and composition share capture, draft, and delivery.
@MainActor
final class TerminalVoiceController: ObservableObject {
    private let log = AppLog("voice")
    enum Mode { case terminal, rename, draft }
    enum NameTarget: String { case window, workspace }
    @Published private(set) var renameTarget: NameTarget = .window

    @Published private(set) var mode: Mode?
    @Published private(set) var targetID: String?
    @Published private(set) var transcript = ""
    @Published private(set) var audioLevels = Array(repeating: 0.0, count: 5)
    @Published private(set) var captureState: SpeechCaptureState = .idle
    @Published private(set) var isSubmitting = false
    @Published private(set) var error: String?

    static let sendDelay: TimeInterval = 3
    @Published private(set) var sendDeadline: Date?
    @Published private(set) var lastSubmission: TerminalVoiceSubmission?
    private let waitBeforeSend: () async throws -> Void
    private var countdownTask: Task<Void, Never>?
    private var countdownID: UUID?
    private var heldTargetID: String?
    private let capture: any SpeechCapturing
    private let availability: (String, Mode) -> Bool
    private let deliver: (TerminalVoiceCommand) async throws -> Void
    private let rename: (String, String, NameTarget) async throws -> Void
    private let hostID: (String) -> String?
    private var committedText = ""
    private var pendingCommand: TerminalVoiceCommand?
    private var captureTask: Task<Void, Never>?
    private var generation = UUID()
    private var submitWhenFinished = false
    private var isSuspended = false
    private var finishDraft: ((String) -> Void)?

    init(capture: any SpeechCapturing,
        waitBeforeSend: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(sendDelay)) },
        isAvailable: @escaping (String, Mode) -> Bool,
        rename: @escaping (String, String, NameTarget) async throws -> Void,
        hostID: @escaping (String) -> String? = { _ in nil },
        deliver: @escaping (TerminalVoiceCommand) async throws -> Void) {
        self.capture = capture
        self.waitBeforeSend = waitBeforeSend
        self.availability = isAvailable
        self.deliver = deliver
        self.rename = rename
        self.hostID = hostID
        capture.onUpdate = { [weak self] in self?.captureUpdated() }
        capture.onFinished = { [weak self] in self?.captureFinished() }
    }

    private func isAvailable(_ id: String) -> Bool {
        guard let mode else { return false }
        return mode == .draft ? finishDraft != nil : availability(id, mode)
    }

    var hasText: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSend: Bool { hasText && sendDeadline == nil && !isSubmitting && captureState != .preparing && captureState != .finishing }
    var canResume: Bool { mode != nil && sendDeadline == nil && !isSubmitting && pendingCommand == nil && captureState != .listening
        && captureState != .preparing && captureState != .finishing }
    var needsRetry: Bool { pendingCommand != nil && !isSubmitting }

    var statusText: String {
        if isSubmitting { return mode == .rename ? "Saving name…" : "Sending…" }
        if sendDeadline != nil { return "Sending in 3 seconds" }
        if let error { return error }
        switch captureState {
        case .preparing: return "Preparing microphone…"
        case .finishing: return "Finishing transcription…"
        case .listening:
            if mode == .rename { return "Say a \(renameTarget.rawValue) name · Pause to save" }
            if mode == .draft { return "Listening · Tap Review when ready" }
            return "Listening"
        case let .failed(message), let .unavailable(message): return message
        case .idle:
            if !hasText { return "Microphone paused" }
            return mode == .rename ? "Name kept · Save or cancel" : "Draft kept"
        }
    }

    /// The press owns one terminal until release or cancellation. Repeated gesture
    /// updates cannot toggle capture or redirect an existing draft.
    func beginTerminalHold(_ id: String) {
        guard !isSubmitting, sendDeadline == nil, pendingCommand == nil,
            captureState != .finishing, availability(id, .terminal) else { return }
        if mode == .terminal && targetID == id {
            guard heldTargetID == nil else { return }
            heldTargetID = id
            resume()
        } else {
            activate(id, mode: .terminal)
            if mode == .terminal && targetID == id { heldTargetID = id }
        }
    }

    func endTerminalHold(_ id: String) {
        guard heldTargetID == id, targetID == id, mode == .terminal else { return }
        heldTargetID = nil
        switch captureState {
        case .listening:
            // Finish even if no partial text has arrived yet; the final callback
            // may contain the first words or correct the last ones.
            submitWhenFinished = true
            capture.finishListening()
        case .finishing:
            // A recognition-task rotation may already be ending this segment.
            submitWhenFinished = true
        case .idle:
            if hasText { scheduleSend() } else { stop() }
        case .preparing:
            // A quick tap or late permission grant must not leave capture armed.
            if hasText { scheduleSend() } else { stop() }
        case .failed, .unavailable:
            pause()
        }
    }

    func cancelTerminalHold(_ id: String) {
        guard heldTargetID == id, targetID == id, mode == .terminal else { return }
        stop()
    }

    func activateRename(_ id: String, target: NameTarget = .window) {
        activate(id, mode: .rename, nameTarget: target)
    }

    /// Local composition uses the same microphone without a terminal destination.
    /// Opening another composer pauses existing input and preserves unsent text.
    @discardableResult
    func activateDraft(_ id: String, text: String = "", onReview: @escaping (String) -> Void) -> Bool {
        guard !isSubmitting else { return false }
        pause()
        guard !hasText && pendingCommand == nil else { return false }
        stop()
        mode = .draft
        targetID = id
        finishDraft = onReview
        committedText = text
        transcript = text
        startCapture()
        return true
    }

    func pause() {
        heldTargetID = nil
        cancelCountdown()
        isSuspended = true
        stopCaptureKeepingDraft()
    }

    private func activate(_ id: String, mode requestedMode: Mode, nameTarget: NameTarget = .window) {
        log.info("capture.requested", ["sessionId": id, "hostId": hostID(id) ?? "", "mode": String(describing: requestedMode)])
        guard !isSubmitting, availability(id, requestedMode) else { return }
        if mode == requestedMode && targetID == id && renameTarget == nameTarget { stop(); return }
        guard !hasText && pendingCommand == nil else {
            error = "Send, save, or cancel the current draft before switching voice input."
            return
        }
        stop()
        mode = requestedMode
        renameTarget = nameTarget
        targetID = id
        startCapture()
    }

    func send() {
        log.info("send.requested", ["sessionId": targetID ?? "", "hostId": targetID.flatMap(hostID) ?? "", "characters": String(transcript.count)])
        guard canSend else { return }
        if captureState == .listening {
            submitWhenFinished = true
            capture.finishListening()
        } else {
            submit()
        }
    }

    func discard() {
        log.info("draft.discarded", ["sessionId": targetID ?? "", "hostId": targetID.flatMap(hostID) ?? ""])
        guard !isSubmitting else { return }
        if mode == .terminal { stop(); return }
        stopCaptureKeepingDraft()
        resetDraft()
        error = nil
        isSuspended = false
        if mode != nil { startCapture() }
    }

    func resume() {
        guard mode != .terminal || heldTargetID == targetID else { return }
        guard canResume, let id = targetID, isAvailable(id) else { return }
        stopCaptureKeepingDraft()
        isSuspended = false
        error = nil
        startCapture()
    }

    /// Permission replies, recognition callbacks, and acknowledgements from an old
    /// interaction must never mutate a newer interaction or change its destination.
    func stop() {
        heldTargetID = nil
        cancelCountdown()
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        capture.stopListening()
        mode = nil
        finishDraft = nil
        targetID = nil
        resetDraft()
        isSubmitting = false
        error = nil
        isSuspended = false
    }

    func targetUnavailable(_ id: String) {
        guard targetID == id, mode != nil else { return }
        heldTargetID = nil
        cancelCountdown()
        isSuspended = true
        stopCaptureKeepingDraft()
        error = "Voice input paused. Continue when the destination is available, or cancel."
        // An unacknowledged command stays immutable so Retry uses its original ID.
    }

    private func startCapture() {
        guard let id = targetID, isAvailable(id), mode != nil, !isSubmitting, !isSuspended else { return }
        captureTask?.cancel()
        let token = generation
        let finishOnPause = mode == .rename
        captureTask = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            await self.capture.startListening(finishOnPause: finishOnPause)
        }
    }

    private func captureUpdated() {
        guard mode != nil else { return }
        if captureState != capture.state {
            captureState = capture.state
            log.info("capture.changed", ["sessionId": targetID ?? "", "hostId": targetID.flatMap(hostID) ?? "", "state": String(describing: capture.state)])
            switch capture.state {
            case .failed, .unavailable:
                heldTargetID = nil
                submitWhenFinished = false
            default: break
            }
        }
        let text = [committedText, capture.transcript].filter { !$0.isEmpty }.joined(separator: " ")
        if transcript != text { transcript = text }
        if audioLevels != capture.audioLevels { audioLevels = capture.audioLevels }
    }

    private func captureFinished() {
        guard mode != nil else { return }
        committedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        capture.clearTranscript()
        if submitWhenFinished || mode == .rename {
            submitWhenFinished = false
            if mode == .terminal {
                if hasText { scheduleSend() } else { stop() }
            } else if hasText { submit() }
        } else {
            // Recognition may finalize a segment itself. Preserve it and continue
            // recording; finalization is not permission to press Return.
            startCapture()
        }
    }

    private func scheduleSend() {
        stopCaptureKeepingDraft()
        guard hasText, let id = targetID, isAvailable(id), !isSuspended else { return }
        cancelCountdown()
        let countdown = UUID()
        countdownID = countdown
        sendDeadline = Date().addingTimeInterval(Self.sendDelay)
        let token = generation
        countdownTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.waitBeforeSend() } catch { return }
            guard !Task.isCancelled, self.generation == token, self.countdownID == countdown else { return }
            self.countdownTask = nil
            self.countdownID = nil
            self.sendDeadline = nil
            self.submit()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownID = nil
        sendDeadline = nil
    }

    private func stopCaptureKeepingDraft() {
        captureTask?.cancel()
        captureTask = nil
        committedText = transcript
        capture.stopListening()
        capture.clearTranscript()
        submitWhenFinished = false
    }

    private func resetDraft() {
        committedText = ""
        pendingCommand = nil
        submitWhenFinished = false
        capture.clearTranscript()
        transcript = ""
    }

    private func submit() {
        guard let id = targetID, hasText, !isSubmitting else { return }
        guard isAvailable(id) else { targetUnavailable(id); return }
        if mode == .draft {
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let completion = finishDraft
            stop()
            completion?(text)
            return
        }
        if mode == .rename {
            let name = WindowName.normalized(transcript)
            stopCaptureKeepingDraft()
            error = nil
            isSubmitting = true
            let token = generation
            Task { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    try await self.rename(id, name, self.renameTarget)
                    guard self.generation == token else { return }
                    self.stop()
                } catch {
                    guard self.generation == token else { return }
                    self.isSubmitting = false
                    self.error = "\(error.localizedDescription) Tap Save Name to retry."
                }
            }
            return
        }
        let command = pendingCommand ?? TerminalVoiceCommand(targetID: id, commandID: UUID().uuidString,
            text: transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n"))
        pendingCommand = command
        stopCaptureKeepingDraft()
        error = nil
        isSubmitting = true
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token else { return }
            do {
                try await self.deliver(command)
                guard self.generation == token else { return }
                self.isSubmitting = false
                self.lastSubmission = TerminalVoiceSubmission(targetID: id, commandID: command.commandID)
                if self.mode == .terminal { self.stop() }
                else {
                    self.resetDraft()
                    self.startCapture()
                }
            } catch {
                guard self.generation == token else { return }
                self.isSubmitting = false
                self.error = "\(error.localizedDescription) Retry sends the same message."
            }
        }
    }
}
