import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechCaptureController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case finishing
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var captureID: UUID?
    private var endpoint = SpeechEndpoint()
    private var endpointTask: Task<Void, Never>?
    private var finalResultTask: Task<Void, Never>?
    private var hasTap = false
    var onFinished: (() -> Void)?

    var isListening: Bool {
        if case .listening = state {
            return true
        }
        return false
    }

    var statusText: String {
        switch state {
        case .idle:
            return transcript.isEmpty ? "Ready to listen" : "Ready to submit"
        case .preparing:
            return "Preparing microphone"
        case .listening:
            return "Pause briefly to send"
        case .finishing:
            return "Finishing transcription…"
        case let .unavailable(message), let .failed(message):
            return message
        }
    }

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func startListening() async {
        guard captureID == nil else { return }
        let id = UUID()
        captureID = id
        transcript = ""
        state = .preparing
        do {
            try await requestPermissions()
            guard captureID == id else { return }
            try configureAndStartRecognition(id: id)
        } catch {
            guard captureID == id else { return }
            stopListening()
            state = .failed(error.localizedDescription)
        }
    }

    /// Cancellation never submits, including delayed permission and recognition callbacks.
    func stopListening() {
        captureID = nil
        endpointTask?.cancel()
        endpointTask = nil
        finalResultTask?.cancel()
        finalResultTask = nil
        stopAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        state = .idle
    }

    private func stopAudio() {
        audioEngine.stop()
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func finishListening() {
        guard isListening, let id = captureID else { return }
        state = .finishing
        endpointTask?.cancel()
        stopAudio()
        recognitionRequest?.endAudio()
        // Give recognition a chance to correct its last partial result before sending.
        finalResultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.captureID == id else { return }
            self.complete()
        }
    }

    private func complete() {
        let hasText = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        stopListening()
        if hasText { onFinished?() }
    }

    func clearTranscript() {
        transcript = ""
        if case .failed = state {
            state = .idle
        }
        if case .unavailable = state {
            state = .idle
        }
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw SpeechCaptureError.permissions("Speech recognition permission was denied.")
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micGranted else {
            throw SpeechCaptureError.permissions("Microphone permission was denied.")
        }

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechCaptureError.unavailable("Speech recognition is unavailable right now.")
        }
    }

    private func configureAndStartRecognition(id: UUID) throws {
        guard let recognizer else {
            throw SpeechCaptureError.unavailable("Speech recognition is unavailable on this device.")
        }

        endpoint = SpeechEndpoint()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
            if sqrt(energy / Float(buffer.frameLength)) > 0.015 {
                Task { @MainActor in
                    guard let self, self.captureID == id, self.isListening else { return }
                    self.endpoint.heardVoice(at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        hasTap = true

        audioEngine.prepare()
        try audioEngine.start()

        transcript = ""
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            Task { @MainActor in
                guard self.captureID == id else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.endpoint.received(self.transcript, at: ProcessInfo.processInfo.systemUptime)
                    if result.isFinal { self.complete(); return }
                }
                if let error {
                    self.stopListening()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        state = .listening
        endpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.captureID == id, self.isListening else { return }
                if self.endpoint.shouldFinish(at: ProcessInfo.processInfo.systemUptime) {
                    self.finishListening()
                    return
                }
            }
        }
    }
}

extension SpeechCaptureController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available {
                self.stopListening()
                self.state = .unavailable("Speech recognition became unavailable.")
            } else if case .unavailable = self.state {
                self.state = .idle
            }
        }
    }
}

private enum SpeechCaptureError: LocalizedError {
    case permissions(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .permissions(message), let .unavailable(message):
            return message
        }
    }
}
