import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechCaptureController: NSObject, SpeechCapturing {
    private(set) var state: SpeechCaptureState = .idle { didSet { onUpdate?() } }
    private(set) var transcript = "" { didSet { onUpdate?() } }
    private(set) var audioLevels = Array(repeating: 0.0, count: 5) { didSet { onUpdate?() } }
    var onUpdate: (() -> Void)?
    private var finishOnPause = true

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var captureID: UUID?
    private var endpoint = SpeechEndpoint()
    private var segment = SpeechRecognitionSegment()
    private var endpointTask: Task<Void, Never>?
    private var finalResultTask: Task<Void, Never>?
    private var hasTap = false
    private var levelMeter = SpeechLevelMeter()
    private var lastLevelUpdate: TimeInterval = 0
    var onFinished: (() -> Void)?

    var isListening: Bool {
        if case .listening = state {
            return true
        }
        return false
    }

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func startListening(finishOnPause: Bool) async {
        guard captureID == nil else { return }
        self.finishOnPause = finishOnPause
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
        levelMeter = SpeechLevelMeter()
        audioLevels = levelMeter.levels
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
        stopListening()
        onFinished?()
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
        segment = SpeechRecognitionSegment()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let session = AVAudioSession.sharedInstance()
        // Terminal notification chimes must remain audible during persistent dictation.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let detectsPauses = finishOnPause
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
            let rms = sqrt(energy / Float(buffer.frameLength))
            Task { @MainActor in
                guard let self, self.captureID == id, self.isListening else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if detectsPauses && rms > 0.015 { self.endpoint.heardVoice(at: now) }
                if now - self.lastLevelUpdate >= 1 / 30 {
                    self.lastLevelUpdate = now
                    self.audioLevels = self.levelMeter.receive(rms: rms)
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
                let finished = self.segment.receive(result?.bestTranscription.formattedString ?? "",
                    isFinal: result?.isFinal == true, hasUtteranceMetadata: result?.speechRecognitionMetadata != nil,
                    isFinishing: self.state == .finishing, hasError: error != nil)
                self.transcript = self.segment.transcript
                if let result, !result.bestTranscription.formattedString.isEmpty {
                    self.endpoint.received(self.transcript, at: ProcessInfo.processInfo.systemUptime)
                }
                // Commit before on-device recognition silently starts another utterance.
                if finished { self.complete(); return }
                if let error {
                    self.stopListening()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        state = .listening
        let startedAt = ProcessInfo.processInfo.systemUptime
        endpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.captureID == id, self.isListening else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if (self.finishOnPause && self.endpoint.shouldFinish(at: now))
                    || (!self.finishOnPause && SpeechRecognitionSegment.shouldRotate(elapsed: now - startedAt)) {
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
