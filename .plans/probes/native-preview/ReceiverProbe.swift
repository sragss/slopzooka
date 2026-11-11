import Foundation
import Network
import CoreMedia
import CoreVideo
import VideoToolbox

private struct ProbeConfig: Decodable, Sendable { let base: String; let token: String; let sourceID: String; let ackDelayMs: Double; let seconds: Double }

nonisolated final class ReceiverProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "slz.local-video-probe")
    private var socket: VideoSocket?
    private var window: VideoReceiveWindow?
    private var samples = WindowVideoSamples()
    private var decoder: VTDecompressionSession?
    private var formatID: UInt64 = 0
    private var finished = false
    private var received = 0
    private var decoded = 0
    private var keyframes = 0
    private var bytes = 0
    private var changes = 0
    private var lastHash: UInt64?
    private var times: [Double] = []
    private var states: [String: Int] = [:]
    private var started = ProcessInfo.processInfo.systemUptime
    private var formats: [[String: Int]] = []
    private var nextSummary: Double = 0
    private var delay: Double = 0
    private var limit: Double = 20

    fileprivate func start(_ config: ProbeConfig) {
        queue.async {
            guard let base = URL(string: config.base),
                  let host = base.host, let port = NWEndpoint.Port(rawValue: UInt16(base.port!)),
                  !config.token.isEmpty, !config.sourceID.isEmpty else { exit(2) }
            self.delay = config.ackDelayMs / 1000
            self.limit = config.seconds
            let request = "GET /api/window-stream/\(config.sourceID) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\nAuthorization: Bearer \(config.token)\r\n\r\n"
            let connection = NWConnection(host: .init(host), port: port, using: .tcp)
            let socket = VideoSocket(connection: connection, request: Data(request.utf8), consume: { packets, _, complete in
                self.queue.async {
                    do {
                        for packet in packets { try self.consume(packet) }
                        self.queue.asyncAfter(deadline: .now() + self.delay) { complete(true) }
                    } catch { self.finish("decode-error", error: String(describing: error)); complete(false) }
                }
            }, ended: { reason in self.queue.async { self.finish(reason.rawValue) } })
            self.socket = socket
            self.started = ProcessInfo.processInfo.systemUptime
            socket.start()
            self.queue.asyncAfter(deadline: .now() + self.limit) { self.finish("completed") }
        }
    }
    private func consume(_ packet: VideoPacket) throws {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if window == nil { window = VideoReceiveWindow(streamID: packet.header.streamID, now: now) }
        let accepted = try window!.receive(packet, now: now)
        if packet.header.kind == .state {
            let state = packet.header.state?.rawValue ?? "unknown"
            states[state, default: 0] += 1
            if state != "idle" { emit(["event":"state", "state":state, "elapsed":now-started]) }
            if ["failed", "sourceGone", "locked", "permissionRequired"].contains(state) { finish("capture-" + state) }
            return
        }
        received += 1; bytes += packet.payload.count
        if packet.header.keyframe { keyframes += 1 }
        guard accepted else { return }
        let sample = try samples.sample(packet)
        if formatID != packet.header.formatID {
            if let decoder { VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: CMSampleBufferGetFormatDescription(sample)!, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &decoder)
            guard status == noErr else { throw VideoFailure.codec(stage: "probe.decoder.create", status: status) }
            formatID = packet.header.formatID
            formats.append(["width": packet.header.width, "height": packet.header.height])
        }
        guard let decoder else { throw VideoFailure.invalidPacket }
        let result = DecodedFrame()
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            if let pointer = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                var hash: UInt64 = 1469598103934665603
                let stride = CVPixelBufferGetBytesPerRow(image)
                for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(image), by: 8) {
                    for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(image) * 4, by: 16) { hash = (hash ^ UInt64(pointer[y * stride + x])) &* 1099511628211 }
                }
                result.value = hash
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        guard status == noErr, let hash = result.value else { throw VideoFailure.codec(stage:"probe.decode",status:status) }
        decoded += 1
        if hash != lastHash { changes += 1; lastHash = hash }
        if times.count < 20000 { times.append(now) }
        if now-started >= nextSummary { nextSummary += 2; emit(["event":"progress","elapsed":now-started,"received":received,"decoded":decoded,"changes":changes,"keyframes":keyframes]) }
    }
    private func finish(_ reason: String, error: String? = nil) {
        guard !finished else { return }; finished = true
        socket?.stop()
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        let gaps = zip(times.dropFirst(), times).map(-).sorted()
        let seconds = ProcessInfo.processInfo.systemUptime-started
        var summary: [String: Any] = ["event":"summary","reason":reason,"seconds":seconds,"received":received,"decoded":decoded,"changes":changes,"keyframes":keyframes,"bytes":bytes,"states":states,"formats":formats,"fps":Double(decoded)/seconds,"gapP50ms":gaps.isEmpty ? 0 : gaps[gaps.count/2]*1000,"gapP95ms":gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count-1)*0.95)]*1000,"gapMaxMs":(gaps.last ?? 0)*1000]
        if let error { summary["error"] = error }
        emit(summary)
        exit(reason == "completed" ? 0 : 1)
    }
    private func emit(_ value: [String: Any]) { FileHandle.standardOutput.write((try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) + Data([10])) }
}
nonisolated private final class DecodedFrame: @unchecked Sendable { var value: UInt64? }
@main struct Main {
    static func main() throws {
        let config = try JSONDecoder().decode(ProbeConfig.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let probe = ReceiverProbe()
        probe.start(config)
        dispatchMain()
    }
}
