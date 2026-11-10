import Foundation
import CoreVideo
import VideoToolbox

@main enum CoreChecks {
    static func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        if !ok() { throw ProbeFailure("check_failed", message) }
    }
    static func rejected(_ expected: String, _ call: () throws -> Void) throws {
        do { try call(); throw ProbeFailure("check_failed", "Expected \(expected)") }
        catch let e as ProbeFailure { try require(e.code == expected, "Expected \(expected), got \(e.code)") }
    }
    static func main() {
        do { try runChecks() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func runChecks() throws {
        var gate = Gate()
        try rejected("not_armed") { try gate.checkDesktop(expected: 1, now: 10) }
        try gate.arm(seconds: 60, now: 10)
        try rejected("desktop_unknown") { try gate.checkDesktop(expected: gate.generation, now: 11) }
        gate.update("unlocked", source: "test", now: 12)
        let prior = gate.generation
        try gate.checkDesktop(expected: prior, now: 13)
        gate.update("locked", source: "test", now: 14)
        try rejected("desktop_locked") { try gate.checkDesktop(expected: prior, now: 15) }
        // Device providers still pass run eligibility under desktop lock.
        try gate.checkRun(now: 15)
        gate.update("unlocked", source: "test", now: 16)
        try rejected("stale_generation") { try gate.checkDesktop(expected: prior, now: 17) }
        try gate.checkDesktop(expected: gate.generation, now: 17)
        try rejected("not_armed") { try gate.checkRun(now: 71) }
        gate.stop()
        try rejected("not_armed") { try gate.checkRun(now: 20) }
        try gate.arm(seconds: 0, now: 20)
        try gate.checkRun(now: 1_000_000)
        gate.stop()
        try rejected("not_armed") { try gate.checkRun(now: 21) }
        print("PASS: deadline, unknown/lock gating, stale actions, independent device eligibility")

        let packet = MediaPacket(header: MediaHeader(kind: "png", generation: 3, sequence: 7), payload: Data((0...255).map(UInt8.init)))
        let encoded = try packet.encoded()
        for stride in [1, 2, 7, 128, encoded.count] {
            var parser = PacketParser(), decoded: [MediaPacket] = []
            for i in Swift.stride(from: 0, to: encoded.count, by: stride) { decoded += try parser.append(encoded.subdata(in: i..<min(encoded.count, i+stride))) }
            try require(decoded.count == 1 && decoded[0].payload == packet.payload && decoded[0].header.sequence == 7, "Fragmented frame lost data")
        }
        var parser = PacketParser()
        let two = try parser.append(encoded + encoded)
        try require(two.count == 2, "Coalesced packets")
        var invalid = PacketParser()
        try rejected("invalid_frame") { _ = try invalid.append(Data(repeating: 255, count: 8)) }
        print("PASS: fragmented/coalesced media and malicious length rejection")

        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let part = Data("--BoundaryString\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n".utf8) + jpeg + Data("\r\n\r\n".utf8)
        var multipart = MultipartJPEGParser(); var images: [Data] = []
        for byte in part + part { images += try multipart.append(Data([byte])) }
        try require(images == [jpeg, jpeg], "Fragmented WDA multipart stream")
        print("PASS: WDA multipart JPEG framing, including empty separators")

        let inbox = StreamInbox(limit: 8)
        inbox.append(Data([1, 2])); inbox.append(Data([3]))
        try require(inbox.drain().0 == Data([1, 2, 3]), "Inbox preserves ordered chunks")
        inbox.append(Data(repeating: 0, count: 9)); inbox.append(Data([4]))
        let overflow = inbox.drain()
        try require(overflow.0.isEmpty && overflow.1 != nil, "Overflow must discard partial stream and fail closed")
        let retry = StreamInbox(); retry.append(Data([5])); inbox.finish("old callback")
        try require(retry.drain().0 == Data([5]), "Old connection cannot affect retry")
        print("PASS: bounded receiver queue, overflow, connection isolation")

        let request = Data("POST /command HTTP/1.1\r\nAuthorization: Bearer test\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for size in 0..<request.count { let result = try ProbeServer.parse(Data(request.prefix(size))); try require(result == nil, "Partial request executed") }
        let parsed = try ProbeServer.parse(request)
        try require(parsed?.authorization == "Bearer test" && parsed?.body == Data("{}".utf8), "HTTP parse")
        try rejected("extra_request") { _ = try ProbeServer.parse(request + request) }
        try rejected("duplicate_header") { _ = try ProbeServer.parse(Data("GET / HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n".utf8)) }
        try rejected("bad_length") { _ = try ProbeServer.parse(Data("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) }
        print("PASS: partial requests, bounded HTTP body, duplicate header/pipelining rejection")

        if CommandLine.arguments.contains("--codec") { try codec() }
        else { print("SKIP: codec smoke test (pass --codec; uses hardware encoder, no screen/UI)") }
    }
    static func codec() throws {
        let encoder = H264Encoder()
        let mutex = NSLock()
        var packets: [MediaPacket] = []
        var callbackError: String?
        encoder.onError = { message in mutex.lock(); callbackError = message; mutex.unlock() }
        try encoder.configure(width: 320, height: 240, generation: 1) { packet in mutex.lock(); packets.append(packet); mutex.unlock() }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == noErr, let buffer else { throw ProbeFailure("check_failed", "Pixel allocation") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 127, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for n in 0..<4 { try encoder.encode(buffer, at: CMTime(value: Int64(n), timescale: 30)) }
        encoder.drain()
        try require(callbackError == nil, callbackError ?? "")
        try require(encoder.hardware, "Hardware encoder was not selected")
        try require(packets.count == 4 && packets[0].header.keyframe, "Missing encoded frames/keyframe")
        var decoder: VTDecompressionSession?
        var decoded = 0
        let count = UnsafeMutablePointer<Int>.allocate(capacity: 1); count.initialize(to: 0)
        defer { count.deinitialize(count: 1); count.deallocate() }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, code, _, image, _, _ in
            if code == noErr, image != nil, let context { context.assumingMemoryBound(to: Int.self).pointee += 1 }
        }, decompressionOutputRefCon: UnsafeMutableRawPointer(count))
        let first = try videoSample(packets[0])
        let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: CMSampleBufferGetFormatDescription(first)!,
            decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &decoder)
        guard result == noErr, let decoder else { throw ProbeFailure("check_failed", "Decoder \(result)") }
        defer { VTDecompressionSessionInvalidate(decoder); encoder.close() }
        for packet in packets {
            let sample = try videoSample(packet)
            let result = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
            try require(result == noErr, "Decode failed \(result)")
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder); decoded = count.pointee
        try require(decoded == 4, "Decoded \(decoded) instead of 4 frames")
        print("PASS: synthetic hardware-required H.264 → sample → decoder, 4 frames; readback property status=\(encoder.hardwareQueryStatus); no screen capture")
    }
}
