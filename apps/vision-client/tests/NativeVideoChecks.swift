import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

@main
struct NativeVideoChecks {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let stream = UUID()
        func frame(_ sequence: UInt64, key: Bool = false, format: UInt64 = 1) -> VideoPacket {
            var header = VideoHeader(kind: .h264, streamID: stream, sequence: sequence, formatID: format,
                width: 640, height: 360, contentWidth: 640, contentHeight: 360, keyframe: key)
            if key { header.parameterSets = [Data([1]), Data([2])] }
            return VideoPacket(header: header, payload: Data([1, 2, 3]))
        }
        func ack(_ sequence: UInt64) -> VideoHeader { VideoHeader(kind: .acknowledgement, streamID: stream, sequence: sequence) }
        func check(_ value: Bool) { precondition(value) }
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected rejection") } catch {}
        }
        let original = frame(1, key: true)
        let wire = try original.encoded()
        for split in 0...wire.count {
            var parser = VideoPacketParser(), decoded: [VideoPacket] = []
            try parser.append(wire.prefix(split)) { decoded.append($0) }
            try parser.append(wire.dropFirst(split)) { decoded.append($0) }
            precondition(decoded == [original] && parser.bufferedBytes == 0)
        }
        var parser = VideoPacketParser(), count = 0
        try parser.append(wire + wire + wire) { _ in count += 1 }
        precondition(count == 3)
        var badPrefix = Data(repeating: 255, count: 12)
        rejects { try parser.append(badPrefix) { _ in } }
        precondition(parser.bufferedBytes == 0)
        badPrefix = wire.prefix(12); badPrefix[8] = 255
        rejects { try parser.append(badPrefix) { _ in } }
        var badVersion = original.header; badVersion.version = 2
        rejects { _ = try VideoPacket(header: badVersion, payload: original.payload).encoded() }
        var hugeSequence = original.header; hugeSequence.sequence = UInt64.max
        rejects { _ = try VideoPacket(header: hugeSequence, payload: original.payload).encoded() }
        print("PASS: fragmented/coalesced native media, bad versions/lengths, and bounded parser reset")

        var slow = VideoSendWindow(streamID: stream), healthy = VideoSendWindow(streamID: stream)
        try check(slow.offer(frame(1, key: true).header, now: 0, writable: true))
        try check(slow.offer(frame(2).header, now: 0.03, writable: true))
        for sequence in 3...100 {
            try check(!slow.offer(frame(UInt64(sequence)).header, now: Double(sequence) / 200, writable: true))
            precondition(slow.outstandingFrames == 2)
            try check(healthy.offer(frame(UInt64(sequence), key: true).header, now: Double(sequence) / 30, writable: true))
            try healthy.acknowledge(ack(UInt64(sequence)))
            precondition(healthy.outstandingFrames == 0)
        }
        rejects { try slow.checkDeadline(now: 1.01) }
        rejects { try slow.acknowledge(ack(99)) }
        try slow.acknowledge(ack(2)); try slow.acknowledge(ack(2))
        try check(!slow.offer(frame(101).header, now: 1.02, writable: true))
        try check(slow.offer(frame(102, key: true).header, now: 1.03, writable: true))
        var wrong = ack(102); wrong.streamID = UUID()
        rejects { try slow.acknowledge(wrong) }
        rejects { try slow.acknowledge(VideoHeader(kind: .stateAcknowledgement, streamID: stream)) }
        print("PASS: stalled receiver bounded to two frames; independent viewer progresses; skipped dependencies require a keyframe")

        var receiver = VideoReceiveWindow(streamID: stream, now: 0)
        try check(!receiver.receive(frame(1), now: 0.01))
        try check(receiver.receive(frame(2, key: true), now: 0.02))
        try check(receiver.receive(frame(3), now: 0.03))
        try check(!receiver.receive(frame(5), now: 0.05))
        try check(receiver.receive(frame(6, key: true), now: 0.06))
        try check(!receiver.receive(frame(7, format: 2), now: 0.07))
        try check(receiver.receive(frame(8, key: true, format: 2), now: 0.08))
        rejects { _ = try receiver.receive(frame(9), now: 2) }
        print("PASS: new format and sequence gaps reset decoder dependencies; inactive receivers reject buffered catch-up")

        try await VideoSocketCheck.run(.normal)
        try await VideoSocketCheck.run(.waiting)
        try await VideoSocketCheck.run(.stalledRenderer)
        try await VideoSocketCheck.run(.invalidMedia)
        print("PASS: real native sockets preserve fragmented binary media and ACKs; stalled renderers time out without ACKs; malformed media never reaches rendering")
        if CommandLine.arguments.contains("--hardware") { try await hardwareRoundtrip() }
    }

    static func hardwareRoundtrip() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "slz.video-test")
            queue.async {
                let driver = HardwareVideoCheck(queue: queue, completion: { continuation.resume(with: $0) })
                driver.start()
            }
        }
    }
}

nonisolated private final class HardwareVideoCheck: @unchecked Sendable {
    let queue: DispatchQueue
    let encoder: WindowVideoEncoder
    let completion: @Sendable (Result<Void, Error>) -> Void
    var retained: HardwareVideoCheck?
    var samples = WindowVideoSamples()
    var finished = false
    var frames = 0
    var buffer: CVPixelBuffer?
    init(queue: DispatchQueue, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.queue = queue; encoder = WindowVideoEncoder(queue: queue); self.completion = completion
    }
    func start() {
        retained = self
        do {
            encoder.onPacket = { [weak self] packet in self?.received(packet) }
            encoder.onFailure = { [weak self] status in self?.finish(.failure(VideoFailure.codec(stage: "encoder.callback", status: status))) }
            try configure(width: 640, height: 360)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(.failure(VideoFailure.stalled)) }
        } catch { finish(.failure(error)) }
    }
    func configure(width: Int, height: Int) throws {
        let properties = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, properties, &buffer) == kCVReturnSuccess,
              let buffer else { throw VideoFailure.invalidPacket }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) { memset(bytes, 100, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try encoder.configure(width: width, height: height, contentWidth: Double(width), contentHeight: Double(height), sourceID: UUID())
        try encoder.encode(buffer, at: CMTime(value: Int64(frames + 1), timescale: 30))
    }
    func received(_ packet: VideoPacket) {
        guard !finished else { return }
        do {
            let wire = try packet.encoded()
            var parser = VideoPacketParser()
            var parsed: VideoPacket?
            try parser.append(wire) { parsed = $0 }
            precondition(parsed == packet)
            let sample = try samples.sample(packet)
            guard let format = CMSampleBufferGetFormatDescription(sample) else { throw VideoFailure.invalidPacket }
            precondition(CMVideoFormatDescriptionGetDimensions(format).width == packet.header.width)
            var decoder: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder) == noErr,
                  let decoder else { throw VideoFailure.invalidPacket }
            let decoded = DecodeResult()
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                decoded.record(status == noErr && image != nil && CVPixelBufferGetWidth(image!) == packet.header.width && CVPixelBufferGetHeight(image!) == packet.header.height)
            }
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            VTDecompressionSessionInvalidate(decoder)
            guard status == noErr, decoded.passed else { throw VideoFailure.codec(stage: "decoder.decode", status: status) }
            frames += 1
            if frames == 1 { try configure(width: 360, height: 640) }
            else {
                print("PASS: real hardware H.264 packets decode to matching pixel dimensions across portrait/landscape format changes")
                finish(.success(()))
            }
        } catch { finish(.failure(error)) }
    }
    func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true; encoder.close(); completion(result); retained = nil
    }
}

nonisolated private final class DecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
