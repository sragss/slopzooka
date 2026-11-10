import Foundation
import Network
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Confined to queue. A viewer has at most two unacknowledged encoded frames,
/// one VT encode and one latest raw image. No unbounded frame tasks or arrays.
nonisolated final class WindowCaptureViewer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let redeem: (UUID) -> SCWindow?
    private let ended: ([String: String]) -> Void
    private let encoder: WindowVideoEncoder
    private var stream: SCStream?
    private var source: SCWindow?
    private var flow: VideoSendWindow
    private var parser = VideoPacketParser()
    private var handshake = Data()
    private var admitted = false
    private var stopped = false
    private var sending = false
    private var timer: DispatchSourceTimer?
    private var raw: CVPixelBuffer?
    private var hasFrame = false
    private var contentSize = CGSize.zero
    private var encodedSize = CGSize.zero
    private var captureSize = CGSize.zero
    private var resizing = false
    private var started: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastCapture: TimeInterval = 0
    private var lastSend: TimeInterval = 0
    private var lastAcknowledgement = ProcessInfo.processInfo.systemUptime
    private var captureIdle = false
    private var frames = 0
    private var bytes = 0
    private var dropped = 0
    private var reason = "disconnected"

    init(id: UUID, connection: NWConnection, queue: DispatchQueue, redeem: @escaping (UUID) -> SCWindow?, ended: @escaping ([String: String]) -> Void) {
        self.id = id; self.connection = connection; self.queue = queue; self.redeem = redeem; self.ended = ended
        encoder = WindowVideoEncoder(queue: queue); flow = VideoSendWindow(streamID: id)
    }
    func start() {
        encoder.onPacket = { [weak self] packet in self?.offer(packet) }
        encoder.onFailure = { [weak self] _ in self?.stop(state: .failed) }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        connection.start(queue: queue)
        receive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, end, error in
            guard let self, !self.stopped else { return }
            do {
                if let data, !data.isEmpty {
                    if !self.admitted {
                        self.handshake.append(data)
                        guard self.handshake.count <= 128 else { throw VideoFailure.invalidPacket }
                        if let newline = self.handshake.firstIndex(of: 10) {
                            guard newline == self.handshake.count - 1,
                                  let text = String(data: self.handshake.prefix(upTo: newline), encoding: .utf8),
                                  let ticket = UUID(uuidString: text), let source = self.redeem(ticket) else { throw VideoFailure.invalidPacket }
                            self.admitted = true; self.lastAcknowledgement = ProcessInfo.processInfo.systemUptime; self.handshake.removeAll(); self.source = source
                            self.contentSize = source.frame.size
                            self.beginCapture(source)
                        }
                    } else {
                        try self.parser.append(data) { packet in
                            if packet.header.kind == .stateAcknowledgement {
                                guard packet.header.streamID == self.id else { throw VideoFailure.invalidAcknowledgement }
                            } else { try self.flow.acknowledge(packet.header) }
                            self.lastAcknowledgement = ProcessInfo.processInfo.systemUptime
                        }
                    }
                }
                if error != nil || end { self.stop() } else { self.receive() }
            } catch { self.stop() }
        }
    }
    private func configuration(_ size: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(2, 1920 / max(size.width, size.height))
        configuration.width = max(2, Int(size.width * scale) / 2 * 2)
        configuration.height = max(2, Int(size.height * scale) / 2 * 2)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        captureSize = CGSize(width: configuration.width, height: configuration.height)
        return configuration
    }
    private func beginCapture(_ window: SCWindow) {
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration(contentSize), delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream.startCapture { [weak self] error in
                guard let self else { return }
                self.queue.async { if error != nil { self.stop(state: .failed) } }
            }
            sendState(.waiting)
        } catch { stop(state: .failed) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let value = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: value) else { return }
        lastCapture = ProcessInfo.processInfo.systemUptime
        captureIdle = status == .idle
        guard status == .complete, let buffer = sample.imageBuffer else {
            if status != .idle { raw = nil; hasFrame = false; encoder.requestKeyframe(); sendState(.waiting) }
            return
        }
        raw = buffer
        encode(buffer, timestamp: sample.presentationTimeStamp)
    }
    private func encode(_ buffer: CVPixelBuffer, timestamp: CMTime) {
        do {
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            guard size == captureSize else { return } // Old geometry during an async SC reconfiguration.
            if size != encodedSize {
                try encoder.configure(width: Int(size.width), height: Int(size.height), contentWidth: contentSize.width,
                    contentHeight: contentSize.height, sourceID: id)
                encodedSize = size
            }
            if flow.needsKeyframe { encoder.requestKeyframe() }
            try encoder.encode(buffer, at: timestamp)
        } catch { stop(state: .failed) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.stop(state: .sourceGone) }
    }
    private func offer(_ packet: VideoPacket) {
        guard !stopped else { return }
        do {
            guard try flow.offer(packet.header, now: ProcessInfo.processInfo.systemUptime, writable: !sending) else { dropped += 1; return }
            hasFrame = true
            let encoded = try packet.encoded()
            frames += 1; bytes += encoded.count
            send(encoded)
        } catch { stop() }
    }
    private func send(_ data: Data, close: Bool = false) {
        guard !sending else { if close { stop() }; return }
        sending = true
        lastSend = ProcessInfo.processInfo.systemUptime
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending = false
            if error != nil || close { self.stop() }
        })
    }
    private func sendState(_ state: VideoHeader.State, close: Bool = false) {
        let packet = VideoPacket(header: VideoHeader(kind: .state, streamID: id, state: state))
        if let data = try? packet.encoded() { send(data, close: close) }
    }
    private func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard admitted else { if now - started > 5 { stop() }; return }
        if now - lastAcknowledgement > 2 { stop(); return }
        if desktopLocked() { stop(state: .locked); return }
        if !CGPreflightScreenCaptureAccess() { stop(state: .permissionRequired); return }
        guard let source,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, source.windowID) as? [[String: Any]])?.first,
              (info[kCGWindowOwnerPID as String] as? Int32) == source.owningApplication?.processID else { stop(state: .sourceGone); return }
        do { try flow.checkDeadline(now: now); try encoder.checkDeadline(now: now) } catch { stop(); return }
        if let bounds = info[kCGWindowBounds as String] as? [String: Any], let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary), rectangle.size != contentSize, !resizing {
            contentSize = rectangle.size
            raw = nil; hasFrame = false; encodedSize = .zero; resizing = true
            stream?.updateConfiguration(configuration(contentSize)) { [weak self] error in
                guard let self else { return }
                self.queue.async { self.resizing = false; if error != nil { self.stop(state: .failed) } }
            }
            sendState(.waiting)
            return
        }
        if !hasFrame {
            if now - started > 10 { stop(state: .failed); return }
            if now - lastSend >= 0.5 { sendState(.waiting) }
        }
        // SCK may stop producing buffers for a static window. A verified source
        // and last complete/idle sample permit a heartbeat, never a frozen error.
        if hasFrame && (captureIdle || now - lastCapture < 1.5) { if !flow.needsKeyframe && now - lastSend >= 0.5 { sendState(.idle) } }
        else if hasFrame { stop(state: .failed); return }
        if flow.needsKeyframe, let raw, flow.outstandingFrames < VideoSendWindow.frameLimit {
            encode(raw, timestamp: CMTime(seconds: now, preferredTimescale: 600))
        }
    }
    private func stop(state: VideoHeader.State? = nil) {
        guard !stopped else { return }
        if let state { reason = state.rawValue }
        if let state, !sending {
            sendState(state, close: true)
            // Teardown now; the final metadata send is the only operation left.
            teardown()
            queue.asyncAfter(deadline: .now() + 0.2) { [connection] in connection.cancel() }
        } else { teardown(); connection.cancel() }
    }
    private func teardown() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        encoder.close(); raw = nil
        stream?.stopCapture { _ in }; stream = nil
        connection.stateUpdateHandler = nil
        ended(["viewerId": id.uuidString, "frames": String(frames), "bytes": String(bytes), "dropped": String(dropped), "reason": reason, "durationMs": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
    }
}
