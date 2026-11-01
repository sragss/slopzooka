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

enum WindowName {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

/// Owns transient voice intent only. WindowGateway resolves IDs and delivers input.
/// One-shot dictation and persistent voice share capture, draft, and delivery.
@MainActor
final class TerminalVoiceController: ObservableObject {
    enum Mode { case dictation, conversation, rename }

    @Published var conversationEnabled: Bool {
        didSet {
            defaults.set(conversationEnabled, forKey: "conversationVoiceEnabled")
            if oldValue != conversationEnabled { stop() }
        }
    }
    @Published private(set) var mode: Mode?
    @Published private(set) var targetID: String?
    @Published private(set) var transcript = ""
    @Published private(set) var audioLevels = Array(repeating: 0.0, count: 5)
    @Published private(set) var captureState: SpeechCaptureState = .idle
    @Published private(set) var isSubmitting = false
    @Published private(set) var error: String?
    @Published private(set) var lastAcknowledgedCommand: TerminalVoiceCommand?

    private let defaults: UserDefaults
    private let capture: any SpeechCapturing
    private let isAvailable: (String) -> Bool
    private let deliver: (TerminalVoiceCommand) async throws -> Void
    private let rename: (String, String) async throws -> Void
    private var committedText = ""
    private var pendingCommand: TerminalVoiceCommand?
    private var captureTask: Task<Void, Never>?
    private var generation = UUID()
    private var submitWhenFinished = false
    private var isSuspended = false

    init(capture: any SpeechCapturing, defaults: UserDefaults = .standard,
        isAvailable: @escaping (String) -> Bool,
        rename: @escaping (String, String) async throws -> Void,
        deliver: @escaping (TerminalVoiceCommand) async throws -> Void) {
        self.capture = capture
        self.defaults = defaults
        self.isAvailable = isAvailable
        self.deliver = deliver
        self.rename = rename
        conversationEnabled = defaults.bool(forKey: "conversationVoiceEnabled")
        capture.onUpdate = { [weak self] in self?.captureUpdated() }
        capture.onFinished = { [weak self] in self?.captureFinished() }
    }

    var hasText: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSend: Bool { hasText && !isSubmitting && captureState != .preparing && captureState != .finishing }
    var canResume: Bool { mode != nil && !isSubmitting && pendingCommand == nil && captureState != .listening
        && captureState != .preparing && captureState != .finishing }
    var needsRetry: Bool { pendingCommand != nil && !isSubmitting }

    var statusText: String {
        if isSubmitting { return mode == .rename ? "Saving name…" : "Sending…" }
        if let error { return error }
        switch captureState {
        case .preparing: return "Preparing microphone…"
        case .finishing: return "Finishing transcription…"
        case .listening:
            if mode == .rename { return "Say a window name · Pause to save" }
            return mode == .dictation ? "Pause briefly to send" : "Listening · Tap Send when ready"
        case let .failed(message), let .unavailable(message): return message
        case .idle:
            if !hasText { return "Microphone paused" }
            return mode == .rename ? "Name kept · Save or discard" : "Draft kept · Send or discard"
        }
    }

    /// Explicit terminal selection works identically in shared and immersive space.
    func activateTerminal(_ id: String) {
        if mode == .rename && targetID == id { stop(); return }
        activate(id, mode: conversationEnabled ? .conversation : .dictation)
    }

    func activateRename(_ id: String) {
        activate(id, mode: .rename)
    }

    private func activate(_ id: String, mode requestedMode: Mode) {
        guard !isSubmitting, isAvailable(id) else { return }
        if mode == requestedMode && targetID == id { stop(); return }
        guard !hasText && pendingCommand == nil else {
            error = "Send, save, or discard the current draft before switching voice input."
            return
        }
        stop()
        mode = requestedMode
        targetID = id
        startCapture()
    }

    func send() {
        guard canSend else { return }
        if captureState == .listening {
            submitWhenFinished = true
            capture.finishListening()
        } else {
            submit()
        }
    }

    func discard() {
        guard !isSubmitting else { return }
        stopCaptureKeepingDraft()
        resetDraft()
        error = nil
        isSuspended = false
        if mode != nil { startCapture() }
    }

    func resume() {
        guard canResume, let id = targetID, isAvailable(id) else { return }
        stopCaptureKeepingDraft()
        isSuspended = false
        error = nil
        startCapture()
    }

    /// Permission replies, recognition callbacks, and acknowledgements from an old
    /// interaction must never mutate a newer interaction or change its destination.
    func stop() {
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        capture.stopListening()
        mode = nil
        targetID = nil
        resetDraft()
        isSubmitting = false
        error = nil
        isSuspended = false
    }

    func targetUnavailable(_ id: String) {
        guard targetID == id, mode != nil else { return }
        isSuspended = true
        stopCaptureKeepingDraft()
        error = "Terminal unavailable. Reconnect, then resume or retry."
        // An unacknowledged command stays immutable so Retry uses its original ID.
    }

    private func startCapture() {
        guard let id = targetID, isAvailable(id), mode != nil, !isSubmitting, !isSuspended else { return }
        captureTask?.cancel()
        let token = generation
        let finishOnPause = mode != .conversation
        captureTask = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            await self.capture.startListening(finishOnPause: finishOnPause)
        }
    }

    private func captureUpdated() {
        guard mode != nil else { return }
        if captureState != capture.state { captureState = capture.state }
        let text = [committedText, capture.transcript].filter { !$0.isEmpty }.joined(separator: " ")
        if transcript != text { transcript = text }
        if audioLevels != capture.audioLevels { audioLevels = capture.audioLevels }
    }

    private func captureFinished() {
        guard mode != nil else { return }
        committedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        capture.clearTranscript()
        if submitWhenFinished || mode != .conversation {
            submitWhenFinished = false
            if hasText { submit() }
        } else {
            // Recognition may finalize a segment itself. Preserve it and continue
            // recording; finalization is not permission to press Return.
            startCapture()
        }
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
        if mode == .rename {
            let name = WindowName.normalized(transcript)
            stopCaptureKeepingDraft()
            error = nil
            isSubmitting = true
            let token = generation
            Task { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    try await self.rename(id, name)
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
                self.lastAcknowledgedCommand = command
                self.isSubmitting = false
                if self.mode == .dictation { self.stop() }
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
