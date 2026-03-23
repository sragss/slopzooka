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
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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
            return "Listening"
        case let .unavailable(message), let .failed(message):
            return message
        }
    }

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func startListening() async {
        if isListening {
            return
        }

        do {
            try await requestPermissions()
            try configureAndStartRecognition()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopListening() {
        guard isListening || recognitionRequest != nil || recognitionTask != nil else {
            return
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if transcript.isEmpty {
            state = .idle
        } else {
            state = .idle
        }
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

    private func configureAndStartRecognition() throws {
        guard let recognizer else {
            throw SpeechCaptureError.unavailable("Speech recognition is unavailable on this device.")
        }

        stopListening()
        state = .preparing

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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        transcript = ""
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }

                if let error {
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.state = .failed(error.localizedDescription)
                    return
                }

                self.state = .listening
            }
        }

        state = .listening
    }
}

extension SpeechCaptureController: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available {
                if self.isListening {
                    self.stopListening()
                }
                self.state = .unavailable("Speech recognition became unavailable.")
            } else if case .unavailable = self.state {
                self.state = self.transcript.isEmpty ? .idle : .idle
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
