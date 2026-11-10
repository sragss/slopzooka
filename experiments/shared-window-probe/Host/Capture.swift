import AppKit
import ScreenCaptureKit
import CoreImage

final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "probe.capture")
    private let encoder = H264Encoder()
    private var stream: SCStream?
    private var latest: CVPixelBuffer?
    private var size = (0, 0)
    private var generation = 0
    var packet: ((MediaPacket) -> Void)?
    var state: ((String) -> Void)?
    var error: ((String) -> Void)?
    func start(window: SCWindow, generation: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = Self.configuration(window)
        self.generation = generation
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        encoder.onError = { [weak self] message in self?.error?(message) }
        try await stream.startCapture()
    }
    static func configuration(_ window: SCWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(2, min(1920 / max(1, window.frame.width), 1440 / max(1, window.frame.height)))
        config.width = max(2, Int(window.frame.width * scale) / 2 * 2)
        config.height = max(2, Int(window.frame.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        config.preservesAspectRatio = true
        config.capturesAudio = false
        return config
    }
    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self, let latest = self.latest else { return }
            self.encoder.requestKeyframe()
            do { try self.encoder.encode(latest, at: CMClockGetTime(CMClockGetHostTimeClock())) }
            catch { self.error?(error.localizedDescription) }
        }
    }
    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { continuation in
            queue.async { self.encoder.close(); self.latest = nil; self.size = (0, 0); continuation.resume() }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { self.error?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status != .complete { state?(String(describing: status)); return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        do {
            if size != (width, height) {
                try encoder.configure(width: width, height: height, generation: generation) { [weak self] packet in self?.packet?(packet) }
                size = (width, height)
            }
            latest = buffer
            state?("complete")
            try encoder.encode(buffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } catch { self.error?(error.localizedDescription) }
    }
    static func screenshot(window: SCWindow) async throws -> Data {
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration(window))
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ProbeFailure("image_encode", "Could not encode screenshot")
        }
        return data
    }
}

final class OwnedProcesses {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    func cancelAll() {
        lock.lock(); let values = Array(processes.values); lock.unlock()
        for p in values where p.isRunning { p.terminate() }
    }
    func run(_ executable: String, _ arguments: [String], timeout: Double) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slz-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("stdout"), err = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        let id = UUID()
        try process.run()
        lock.withLock { processes[id] = process }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            lock.withLock { processes[id] = nil }
        }
        let deadline = uptime() + timeout
        while process.isRunning {
            try Task.checkCancellation()
            if uptime() >= deadline { throw ProbeFailure("process_timeout", "\(arguments.prefix(3).joined(separator: " ")) exceeded its deadline") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard process.terminationStatus == 0 else {
            let data = try Data(contentsOf: err)
            throw ProbeFailure("process_failed", String(decoding: data.prefix(3000), as: UTF8.self))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size < 16 * 1024 * 1024 else { throw ProbeFailure("output_limit", "Process output too large") }
        return try Data(contentsOf: out)
    }
}
