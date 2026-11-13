@preconcurrency import AVFoundation
import Foundation
import Darwin
@preconcurrency import Speech

@MainActor
final class SpeechCaptureController: SpeechCapturing {
    private(set) var state: SpeechCaptureState = .idle { didSet { onUpdate?() } }
    private(set) var transcript = "" { didSet { onUpdate?() } }
    private(set) var audioLevels = Array(repeating: 0.0, count: 5) { didSet { onAudioLevels?() } }
    var onAudioLevels: (() -> Void)?
    var onUpdate: (() -> Void)?
    private var finishOnPause = true

    private let worker = SpeechCaptureWorker { AudioSpeechSession(attempt: $0, emit: $1) }
    private let log = AppLog("speech-capture")
    private var attempt: SpeechCaptureAttempt?
    private var captureID: UUID?
    private var endpoint = SpeechEndpoint()
    private var segment = SpeechRecognitionSegment()
    private var endpointTask: Task<Void, Never>?
    private var finalResultTask: Task<Void, Never>?
    private var meterSamples = 0
    private var totalHandoffMs = 0.0
    private var maxHandoffMs = 0.0
    var onFinished: (() -> Void)?

    var isListening: Bool {
        if case .listening = state {
            return true
        }
        return false
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
            endpoint = SpeechEndpoint()
            segment = SpeechRecognitionSegment()
            let attempt = SpeechCaptureAttempt()
            self.attempt = attempt
            try await log.operation("capture.start") {
                try await worker.start(attempt: attempt) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        if case let .timing(fields) = event {
                            self.log.child(["captureId": id.uuidString]).info("capture.audio.timing", fields.mapValues { String($0) })
                            return
                        }
                        guard self.captureID == id else { return }
                        self.receive(event)
                    }
                }
            }
            guard captureID == id else { return }
            state = .listening
            monitorEndpoint(id: id)
        } catch {
            guard captureID == id else { return }
            stopListening()
            state = .failed(error.localizedDescription)
        }
    }

    /// Cancellation never submits, including delayed permission and recognition callbacks.
    func stopListening() {
        if meterSamples > 0 {
            log.child(["captureId": captureID?.uuidString ?? ""]).info("capture.meter.timing", [
                "samples": String(meterSamples), "meanHandoffMs": String(totalHandoffMs / Double(meterSamples)),
                "maxHandoffMs": String(maxHandoffMs),
            ])
        }
        meterSamples = 0
        totalHandoffMs = 0
        maxHandoffMs = 0
        captureID = nil
        endpointTask?.cancel()
        endpointTask = nil
        finalResultTask?.cancel()
        finalResultTask = nil
        if let attempt { worker.stop(attempt: attempt) }
        attempt = nil
        audioLevels = Array(repeating: 0, count: 5)
        state = .idle
    }

    func finishListening() {
        guard isListening, let id = captureID else { return }
        state = .finishing
        endpointTask?.cancel()
        // Give recognition a chance to correct its last partial result before sending.
        finalResultTask = Task { [weak self] in
            guard let self, let attempt = self.attempt else { return }
            await self.worker.finish(attempt: attempt)
            guard !Task.isCancelled, self.captureID == id else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.captureID == id else { return }
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
    }

    private func receive(_ event: SpeechCaptureWorker.Event) {
        switch event {
        case let .levels(levels, heardVoice, producedAt):
            guard isListening else { return }
            let handoffMs = max(0, ProcessInfo.processInfo.systemUptime - producedAt) * 1000
            meterSamples += 1
            totalHandoffMs += handoffMs
            maxHandoffMs = max(maxHandoffMs, handoffMs)
            if finishOnPause && heardVoice { endpoint.heardVoice(at: ProcessInfo.processInfo.systemUptime) }
            audioLevels = levels
        case .timing: break // Recorded at intake, even after the attempt has ended.
        case let .availability(available):
            if !available {
                stopListening()
                state = .unavailable("Speech recognition became unavailable.")
            }
        case let .recognition(text, isFinal, hasMetadata, error):
            let finished = segment.receive(text, isFinal: isFinal, hasUtteranceMetadata: hasMetadata,
                isFinishing: state == .finishing, hasError: error != nil)
            transcript = segment.transcript
            if !text.isEmpty { endpoint.received(transcript, at: ProcessInfo.processInfo.systemUptime) }
            if finished { complete(); return }
            if let error {
                stopListening()
                state = .failed(error)
            }
        }
    }

    private func monitorEndpoint(id: UUID) {
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

nonisolated private enum SpeechCaptureError: LocalizedError {
    case permissions(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .permissions(message), let .unavailable(message):
            return message
        }
    }
}

nonisolated private final class AudioSpeechSession: NSObject, SpeechCaptureSession, SFSpeechRecognizerDelegate {
    let attempt: SpeechCaptureAttempt
    let emit: @Sendable (SpeechCaptureWorker.Event) -> Void
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var hasTap = false
    private var isActive = false

    init(attempt: SpeechCaptureAttempt, emit: @escaping @Sendable (SpeechCaptureWorker.Event) -> Void) {
        self.attempt = attempt
        self.emit = emit
        super.init()
        recognizer?.delegate = self
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        emit(.availability(available))
    }

    func start() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechCaptureError.unavailable("Speech recognition is unavailable right now.")
        }
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        let preferredBufferAccepted = (try? audio.setPreferredIOBufferDuration(0.01)) != nil
        try audio.setActive(true)
        isActive = true
        try attempt.checkCancellation()
        emit(.timing(["requestedIOBufferMs": 10, "preferredBufferAccepted": preferredBufferAccepted ? 1 : 0,
            "actualIOBufferMs": audio.ioBufferDuration * 1000, "inputLatencyMs": audio.inputLatency * 1000,
            "sampleRate": audio.sampleRate]))

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let tap = AudioTap(request: request, emit: emit)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, time in tap.receive(buffer, time: time) }
        hasTap = true
        engine.prepare()
        try attempt.checkCancellation()
        try engine.start()
        let emit = emit
        task = recognizer.recognitionTask(with: request) { result, error in
            emit(.recognition(result?.bestTranscription.formattedString ?? "", isFinal: result?.isFinal == true,
                hasMetadata: result?.speechRecognitionMetadata != nil, error: error?.localizedDescription))
        }
        try attempt.checkCancellation()
    }

    func finish() {
        stopAudio()
        request.endAudio()
    }

    func stop() {
        stopAudio()
        task?.cancel()
        task = nil
    }

    private func stopAudio() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        if isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
        }
    }
}

/// AVAudioEngine serializes callbacks for this tap. Meter state never crosses
/// threads, and throttling happens before scheduling any UI work.
nonisolated private final class AudioTap: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let emit: @Sendable (SpeechCaptureWorker.Event) -> Void
    private var meter = SpeechLevelMeter()
    private var lastUpdate: TimeInterval = 0
    private var heardVoice = false
    private var bufferCount = 0
    private var totalBufferMs = 0.0
    private var totalIntervalMs = 0.0
    private var previousCallbackAt: TimeInterval?
    private var maxBufferAgeMs = 0.0
    private var maxBufferEndAgeMs = 0.0

    init(request: SFSpeechAudioBufferRecognitionRequest, emit: @escaping @Sendable (SpeechCaptureWorker.Event) -> Void) {
        self.request = request
        self.emit = emit
    }

    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { request.append(buffer) }
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let bufferMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        bufferCount += 1
        totalBufferMs += bufferMs
        if let previousCallbackAt { totalIntervalMs += (now - previousCallbackAt) * 1000 }
        previousCallbackAt = now
        if time.isHostTimeValid {
            let ageMs = (AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: time.hostTime)) * 1000
            maxBufferAgeMs = max(maxBufferAgeMs, ageMs)
            maxBufferEndAgeMs = max(maxBufferEndAgeMs, ageMs - bufferMs)
        }
        // Bounded summaries identify actual tap buffering without logging audio,
        // microphone levels, transcripts, or one event per callback.
        if bufferCount == 1 || bufferCount == 10 {
            emit(.timing(["buffers": Double(bufferCount), "meanBufferMs": totalBufferMs / Double(bufferCount),
                "meanCallbackIntervalMs": totalIntervalMs / Double(max(1, bufferCount - 1)),
                "maxBufferAgeMs": maxBufferAgeMs, "maxBufferEndAgeMs": maxBufferEndAgeMs]))
        }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        let rms = sqrt(energy / Float(buffer.frameLength))
        heardVoice = heardVoice || rms > 0.015
        guard now - lastUpdate >= 1 / 60 else { return }
        lastUpdate = now
        let levels = meter.receive(samples: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)),
            sampleRate: buffer.format.sampleRate)
        emit(.levels(levels, heardVoice: heardVoice, producedAt: now))
        heardVoice = false
    }
}
