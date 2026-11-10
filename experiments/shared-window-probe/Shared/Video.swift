import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

func videoSample(_ packet: MediaPacket) throws -> CMSampleBuffer {
    let sets = packet.header.parameterSets
    guard sets.count == 2, !sets.contains(where: { $0.isEmpty }), !packet.payload.isEmpty else {
        throw ProbeFailure("bad_video", "Missing H.264 parameter sets or payload")
    }
    var format: CMFormatDescription?
    let result = sets[0].withUnsafeBytes { a in
        sets[1].withUnsafeBytes { b -> OSStatus in
            let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = sets.map(\.count)
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
    }
    guard result == noErr, let format else { throw ProbeFailure("bad_format", "H.264 format \(result)") }
    var block: CMBlockBuffer?
    var code = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: packet.payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: packet.payload.count, flags: 0, blockBufferOut: &block)
    guard code == noErr, let block else { throw ProbeFailure("bad_buffer", "Block allocation \(code)") }
    code = packet.payload.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.payload.count)
    }
    guard code == noErr else { throw ProbeFailure("bad_buffer", "Block copy \(code)") }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(packet.header.sequence), timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var size = packet.payload.count
    code = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard code == noErr, let sample else { throw ProbeFailure("bad_sample", "Sample creation \(code)") }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
        attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    return sample
}

#if os(macOS)
final class H264Encoder {
    private var session: VTCompressionSession?
    private var handler: ((MediaPacket) -> Void)?
    private var generation = 0
    private var dimensions = (0, 0)
    private var sequence = 0
    private var forceKey = true
    private(set) var hardware = false
    private(set) var hardwareQueryStatus: OSStatus = 0
    var onError: ((String) -> Void)?
    // Owner methods use its serial capture queue. VT supplies ordered output callbacks;
    // close drains them before clearing callback state or releasing the encoder.
    func configure(width: Int, height: Int, generation: Int, handler: @escaping (MediaPacket) -> Void) throws {
        close()
        self.handler = handler; self.generation = generation; dimensions = (width, height)
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let callback: VTCompressionOutputCallback = { context, _, status, _, sample in
            guard let context else { return }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(context).takeUnretainedValue()
            guard status == noErr, let sample else { encoder.onError?("Encoder callback \(status)"); return }
            encoder.output(sample)
        }
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard result == noErr, let session else { throw ProbeFailure("encoder_unavailable", "Hardware H.264 creation \(result)") }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, true as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, false as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, 8_000_000 as CFTypeRef),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFTypeRef),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 30 as CFTypeRef)] {
            let r = VTSessionSetProperty(session, key: key, value: value)
            guard r == noErr else { close(); throw ProbeFailure("encoder_setting", "\(key): \(r)") }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { close(); throw ProbeFailure("encoder_prepare", "Prepare returned \(prepared)") }
        var raw: UnsafeRawPointer?
        hardwareQueryStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &raw)
        // Creation above REQUIRES hardware and fails if unavailable. Some low-latency
        // encoders don't expose the redundant readback property (-12900 on this Mac).
        hardware = true
        if hardwareQueryStatus == noErr, let raw {
            hardware = (Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue() as? Bool) == true
            guard hardware else { close(); throw ProbeFailure("encoder_hardware", "Hardware property unexpectedly false") }
        }
    }
    func requestKeyframe() { forceKey = true }
    func encode(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        guard let session else { throw ProbeFailure("encoder_closed", "Encoder is closed") }
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
            duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        guard result == noErr else { throw ProbeFailure("encode_failed", "Encode returned \(result)") }
    }
    func drain() { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
    func close() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil; handler = nil; sequence = 0; forceKey = true; hardware = false
    }
    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
            sets.append(Data(bytes: pointer, count: size))
        }
        var payload = Data(count: CMBlockBufferGetDataLength(block))
        let result = payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard result == noErr else { onError?("Encoded buffer copy \(result)"); return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        sequence += 1
        handler?(MediaPacket(header: MediaHeader(kind: "h264", generation: generation, sequence: sequence,
            timestamp: uptime(), width: dimensions.0, height: dimensions.1, keyframe: key, parameterSets: sets), payload: payload))
    }
    deinit { close() }
}
#endif
