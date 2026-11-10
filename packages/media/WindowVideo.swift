import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

nonisolated struct WindowVideoSamples {
    private var format: CMFormatDescription?
    private var formatID: UInt64 = 0
    mutating func reset() { format = nil; formatID = 0 }
    mutating func sample(_ packet: VideoPacket) throws -> CMSampleBuffer {
        try packet.header.validate(payloadBytes: packet.payload.count)
        let header = packet.header
        guard header.kind == .h264 else { throw VideoFailure.invalidPacket }
        if header.keyframe {
            let sets = header.parameterSets
            var description: CMFormatDescription?
            let status = sets[0].withUnsafeBytes { first in
                sets[1].withUnsafeBytes { second -> OSStatus in
                    let pointers = [first.bindMemory(to: UInt8.self).baseAddress!, second.bindMemory(to: UInt8.self).baseAddress!]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                }
            }
            guard status == noErr, let description else { throw VideoFailure.invalidPacket }
            let size = CMVideoFormatDescriptionGetDimensions(description)
            guard size.width == header.width, size.height == header.height else { throw VideoFailure.invalidPacket }
            format = description; formatID = header.formatID
        }
        guard let format, formatID == header.formatID else { throw VideoFailure.invalidPacket }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: packet.payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: packet.payload.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw VideoFailure.invalidPacket }
        let copied = packet.payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard copied == noErr else { throw VideoFailure.invalidPacket }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(header.sequence), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = packet.payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { throw VideoFailure.invalidPacket }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

#if os(macOS)
/// Called on its owner queue. Only one encode is outstanding; capture may drop a
/// raw frame instead of growing a queue. close() drains VT before releasing self.
nonisolated final class WindowVideoEncoder: @unchecked Sendable {
    private let queue: DispatchQueue
    private var session: VTCompressionSession?
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var inFlight = false
    private var encodeStarted: TimeInterval = 0
    private var forceKeyframe = true
    private var header: VideoHeader?
    var onPacket: (@Sendable (VideoPacket) -> Void)?
    var onFailure: (@Sendable (OSStatus) -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }

    deinit {
        // VT holds an unretained callback context. Drain it even if an owner
        // unexpectedly releases the encoder without calling close().
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    func configure(width: Int, height: Int, contentWidth: Double, contentHeight: Double, sourceID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        close()
        guard (2...4096).contains(width), (2...4096).contains(height), width * height <= 8_388_608 else { throw VideoFailure.invalidPacket }
        var header = VideoHeader(kind: .h264, streamID: sourceID)
        header.formatID = epoch; header.width = width; header.height = height
        header.contentWidth = contentWidth; header.contentHeight = contentHeight
        self.header = header
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        let callback: VTCompressionOutputCallback = { context, _, status, flags, sample in
            guard let context else { return }
            let encoder = Unmanaged<WindowVideoEncoder>.fromOpaque(context).takeUnretainedValue()
            // VT output is consumed before returning. Only Sendable packet data
            // crosses back to the owner queue, not a borrowed CMSampleBuffer.
            let epoch = encoder.epoch
            let packet = status == noErr ? sample.flatMap { encoder.packet($0) } : nil
            encoder.queue.async { [weak encoder] in
                guard let encoder, encoder.epoch == epoch else { return }
                encoder.inFlight = false
                if status == noErr && flags.contains(.frameDropped) { encoder.forceKeyframe = true; return }
                guard var packet else { encoder.onFailure?(status == noErr ? -1 : status); return }
                encoder.sequence += 1; packet.header.sequence = encoder.sequence
                encoder.onPacket?(VideoPacket(header: packet.header, payload: packet.payload))
            }
        }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: callback, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard status == noErr, let session else { throw VideoFailure.codec(stage: "encoder.create", status: status) }
        do {
            for (key, value) in [
                (kVTCompressionPropertyKey_RealTime, true as CFTypeRef),
                (kVTCompressionPropertyKey_AllowFrameReordering, false as CFTypeRef),
                (kVTCompressionPropertyKey_AverageBitRate, 8_000_000 as CFTypeRef),
                (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFTypeRef),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, 30 as CFTypeRef),
            ] {
                let result = VTSessionSetProperty(session, key: key, value: value)
                guard result == noErr else { throw VideoFailure.codec(stage: "encoder.property.\(key)", status: result) }
            }
            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw VideoFailure.codec(stage: "encoder.prepare", status: prepared) }
        } catch { close(); throw error }
    }
    func checkDeadline(now: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if inFlight && now - encodeStarted > 1 { throw VideoFailure.stalled }
    }
    func requestKeyframe() { dispatchPrecondition(condition: .onQueue(queue)); forceKeyframe = true }
    @discardableResult func encode(_ buffer: CVPixelBuffer, at timestamp: CMTime) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session else { throw VideoFailure.invalidPacket }
        guard !inFlight else { return false }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        inFlight = true; encodeStarted = ProcessInfo.processInfo.systemUptime; forceKeyframe = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: timestamp,
            duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { inFlight = false; throw VideoFailure.codec(stage: "encoder.encode", status: status) }
        return true
    }
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil; epoch += 1; inFlight = false; forceKeyframe = true; header = nil
    }
    private func packet(_ sample: CMSampleBuffer) -> (header: VideoHeader, payload: Data)? {
        guard var header, let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        header.keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        if header.keyframe {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer, size <= 4096 else { return nil }
                header.parameterSets.append(Data(bytes: pointer, count: size))
            }
        }
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0, size <= VideoPacket.maximumPayload else { return nil }
        var payload = Data(count: size)
        let copied = payload.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard copied == noErr else { return nil }
        return (header, payload)
    }
}
#endif
