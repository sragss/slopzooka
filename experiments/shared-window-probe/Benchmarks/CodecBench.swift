// Standalone, offline experiment. No screen capture, app control, or network listeners.
import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import CoreMedia
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers
import Darwin

func benchNow() -> Double { ProcessInfo.processInfo.systemUptime }
struct Failure: Error, CustomStringConvertible { let description: String }
func check(_ status: OSStatus, _ name: String) throws {
    if status != noErr { throw Failure(description: "\(name): OSStatus \(status)") }
}
struct Options {
    var codec = "h264", mode = "lowlatency", pattern = "scroll", input = "raw"
    var width = 1920, height = 1080, fps = 30, streams = 1, mbps = 8
    var warmup = 2, seconds = 6, output = "", images = false
    init() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count % 2 == 0 else { throw Failure(description: "Arguments must be --key value pairs") }
        for i in stride(from: 0, to: args.count, by: 2) {
            let value = args[i+1]
            switch args[i] {
            case "--codec": codec = value
            case "--mode": mode = value
            case "--pattern": pattern = value
            case "--input": input = value
            case "--width": width = Int(value) ?? 0
            case "--height": height = Int(value) ?? 0
            case "--fps": fps = Int(value) ?? 0
            case "--streams": streams = Int(value) ?? 0
            case "--mbps": mbps = Int(value) ?? 0
            case "--warmup": warmup = Int(value) ?? -1
            case "--seconds": seconds = Int(value) ?? 0
            case "--output": output = value
            case "--images": images = value == "true"
            default: throw Failure(description: "Unknown argument \(args[i])")
            }
        }
        guard ["h264", "hevc"].contains(codec), ["lowlatency", "realtime"].contains(mode),
              ["static", "scroll", "motion"].contains(pattern), ["raw", "jpeg"].contains(input),
              width > 0, height > 0, width <= 2560, height <= 2560, width % 2 == 0, height % 2 == 0,
              (1...60).contains(fps), (1...3).contains(streams), (1...20).contains(mbps),
              (0...5).contains(warmup), (1...30).contains(seconds), !output.isEmpty
        else { throw Failure(description: "Invalid benchmark configuration") }
    }
    var json: [String: Any] {
        ["codec": codec, "mode": mode, "pattern": pattern, "input": input,
         "width": width, "height": height, "fps": fps, "streams": streams, "targetMbpsPerStream": mbps,
         "warmupSeconds": warmup, "measurementSeconds": seconds, "maxInFlightPerStream": 3,
         "jpegQuality": 0.25, "corpusFrames": pattern == "static" ? 1 : 60]
    }
}
func allocate(_ w: Int, _ h: Int, _ format: OSType) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    try check(CVPixelBufferCreate(nil, w, h, format,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer), "allocate")
    guard let buffer else { throw Failure(description: "Missing pixel buffer") }
    return buffer
}
final class Pixels {
    let width: Int, height: Int
    var transfer: VTPixelTransferSession!
    init(_ w: Int, _ h: Int) throws {
        width = w; height = h
        try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer), "pixel transfer")
    }
    deinit { VTPixelTransferSessionInvalidate(transfer) }
    func convert(_ source: CVPixelBuffer, to format: OSType) throws -> CVPixelBuffer {
        let destination = try allocate(width, height, format)
        try check(VTPixelTransferSessionTransferImage(transfer, from: source, to: destination), "transfer image")
        return destination
    }
    func context(_ buffer: CVPixelBuffer) throws -> CGContext {
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure(description: "CGContext allocation") }
        return context
    }
    func render(_ frame: Int, _ pattern: String) throws -> (CVPixelBuffer, CGImage) {
        let buffer = try allocate(width, height, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let c = try context(buffer)
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ rgb: [CGFloat]) {
            c.setFillColor(CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1))
            c.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        func text(_ value: String, _ x: Double, _ y: Double, _ size: CGFloat, _ rgb: [CGFloat]) {
            let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, size, nil),
                kCTForegroundColorAttributeName: CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes:
                Dictionary(uniqueKeysWithValues: attributes.map { (NSAttributedString.Key($0.key as String), $0.value) })))
            c.saveGState(); c.translateBy(x: x, y: y + Double(size)); c.scaleBy(x: 1, y: -1)
            c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
        }
        let w = Double(width), h = Double(height), split = w * 0.63
        rect(0, 0, w, h, [0.96, 0.97, 0.98]); rect(0, 0, w, 54, [0.08, 0.11, 0.17])
        text("SlopZooka / codec fixture / \(pattern)", 22, 14, 21, [0.93, 0.95, 0.98])
        rect(14, 67, split-26, h-83, [1, 1, 1])
        c.saveGState(); c.clip(to: CGRect(x: 20, y: 75, width: split-38, height: h-94))
        let offset = pattern == "scroll" ? Double(frame) * 3 : 0
        for row in 0..<90 {
            let y = 81 + Double(row)*23 - offset
            if row % 2 == 0 { rect(20, y-1, split-38, 23, [0.94, 0.95, 0.97]) }
            let color: [CGFloat] = row % 3 == 0 ? [0.04, 0.37, 0.66] : [0.12, 0.16, 0.22]
            text(String(format: "%03d  settings.input[%02d] = \"Aa0O1Il — %04x\";", row, row%23, (row*7919)%65536), 28, y, 14, color)
        }
        c.restoreGState()
        rect(split+3, 67, w-split-17, h-83, [0.08, 0.10, 0.14])
        text("PREVIEW / STATUS", split+17, 85, 16, [0.67, 0.77, 0.91])
        for row in 0..<min(28, height/27) {
            let color: [CGFloat] = row % 2 == 0 ? [0.4, 0.9, 0.68] : [0.95, 0.65, 0.4]
            text("\(row%2 == 0 ? "ready" : "event")  \(row)  Aa0O / 123", split+17, 119+Double(row)*24, 13, color)
        }
        if pattern == "motion" {
            for bar in 0..<18 {
                let value = (sin(Double(frame)*Double.pi/30 + Double(bar)*0.5)+1)*0.5
                rect(split+18+Double(bar)*max(5,(w-split-45)/18), h*0.63+value*80,
                     max(3,(w-split-70)/18), h*0.23-value*80, [0.1+CGFloat(bar%3)*0.2, 0.58, 0.84])
            }
            let x = 35 + Double(frame)/59 * (split-150)
            rect(x, h*0.45, 100, 90, [0.16, 0.49, 0.91])
            text("drag \(frame)", x+8, h*0.45+30, 15, [1,1,1])
        }
        guard let image = c.makeImage() else { throw Failure(description: "CG image") }
        return (buffer, image)
    }
    func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure(description: "JPEG destination") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.25] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "JPEG encode") }
        return data as Data
    }
    func decodeJPEG(_ data: Data) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure(description: "JPEG decode") }
        let bgra = try allocate(width, height, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, [])
        let c = try context(bgra)
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(bgra, [])
        return try convert(bgra, to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    func save(_ buffer: CVPixelBuffer, _ path: String) throws {
        let bgra = try convert(buffer, to: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, .readOnly); defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        guard let image = try context(bgra).makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "PNG output") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "PNG finalize") }
    }
}
struct Source { let pixels: CVPixelBuffer; let jpeg: Data }
final class Tag {
    let sequence: Int, source: Int, measured: Bool, begin: Double, submit: Double
    var decodeBegin = 0.0
    init(_ seq: Int, _ source: Int, _ measured: Bool, _ begin: Double, _ submit: Double) {
        sequence=seq; self.source=source; self.measured=measured; self.begin=begin; self.submit=submit
    }
}
final class Log {
    let lock = NSLock()
    var events: [[String: Any]] = []
    func add(_ value: [String: Any]) { lock.lock(); events.append(value); lock.unlock() }
}
func property(_ session: VTSession, _ key: CFString) -> [String: Any] {
    var raw: UnsafeRawPointer?
    let code = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &raw)
    var result: [String: Any] = ["status": code]
    if code == noErr, let raw { result["value"] = String(describing: Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()) }
    return result
}
final class Codec {
    let options: Options, id: Int, log: Log
    let lock = NSLock(), queue: DispatchQueue
    var encoder: VTCompressionSession?, decoder: VTDecompressionSession?
    var active: [Int: Tag] = [:], errors: [String] = []
    var encoded = 0, decoded = 0, bytes = 0, keyframes = 0, rejected = 0, dropped = 0
    var encodeMS: [Double] = [], decodeMS: [Double] = [], roundtripMS: [Double] = [], submitMS: [Double] = []
    var samples: [(Int, CVPixelBuffer)] = []
    init(_ options: Options, _ id: Int, _ log: Log) throws {
        self.options=options; self.id=id; self.log=log; queue=DispatchQueue(label: "bench.decode.\(id)")
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if options.mode == "lowlatency" { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let code = VTCompressionSessionCreate(allocator: nil, width: Int32(options.width), height: Int32(options.height),
            codecType: options.codec == "h264" ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, source, code, flags, sample in
                guard let context, let source else { return }
                let owner = Unmanaged<Codec>.fromOpaque(context).takeUnretainedValue()
                let tag = Unmanaged<Tag>.fromOpaque(source).takeUnretainedValue()
                owner.output(tag, code, flags, sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
        log.add(["stream": id, "operation": "createEncoder", "status": code, "hardwareRequired": true])
        try check(code, "create \(options.codec) \(options.mode)")
        guard let encoder else { throw Failure(description: "Missing encoder") }
        let props: [(CFString, Any)] = [(kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_AverageBitRate, options.mbps*1_000_000),
            (kVTCompressionPropertyKey_ExpectedFrameRate, options.fps),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, options.fps)]
        for (key, value) in props {
            let status = VTSessionSetProperty(encoder, key: key, value: value as CFTypeRef)
            log.add(["stream": id, "property": key as String, "setStatus": status])
            try check(status, key as String)
        }
        // This optional property is measured rather than silently assumed supported.
        let delay = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        log.add(["stream": id, "property": "MaxFrameDelayCount", "requested": 0, "setStatus": delay])
        try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "prepare encoder")
        for key in [kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, kVTCompressionPropertyKey_EncoderID,
                    kVTCompressionPropertyKey_AllowFrameReordering, kVTCompressionPropertyKey_MaxFrameDelayCount] {
            log.add(["stream": id, "property": key as String, "readback": property(encoder, key)])
        }
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return active.count }
    func submit(_ pixels: CVPixelBuffer, source: Int, sequence: Int, begin: Double, measured: Bool) {
        let tag = Tag(sequence, source, measured, begin, benchNow())
        lock.lock(); active[sequence] = tag; lock.unlock()
        let status = VTCompressionSessionEncodeFrame(encoder!, imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: Int64(sequence), timescale: CMTimeScale(options.fps)),
            duration: CMTime(value: 1, timescale: CMTimeScale(options.fps)), frameProperties: nil,
            sourceFrameRefcon: Unmanaged.passUnretained(tag).toOpaque(), infoFlagsOut: nil)
        lock.lock()
        if measured { submitMS.append((benchNow()-tag.submit)*1000) }
        if status != noErr { errors.append("encode submit \(status)"); active.removeValue(forKey: sequence) }
        lock.unlock()
    }
    func output(_ tag: Tag, _ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?) {
        lock.lock()
        guard status == noErr, let sample else {
            if flags.contains(.frameDropped) { if tag.measured { dropped += 1 } }
            else { errors.append("encode callback \(status), no sample") }
            active.removeValue(forKey: tag.sequence); lock.unlock(); return
        }
        if tag.measured {
            encoded += 1; bytes += CMSampleBufferGetTotalSampleSize(sample)
            encodeMS.append((benchNow()-tag.submit)*1000)
            let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if a?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true { keyframes += 1 }
        }
        lock.unlock()
        queue.async { [self] in
            do {
                if decoder == nil {
                    guard let format = CMSampleBufferGetFormatDescription(sample) else { throw Failure(description: "No video format") }
                    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, source, code, _, image, _, _ in
                        guard let context, let source else { return }
                        let owner = Unmanaged<Codec>.fromOpaque(context).takeUnretainedValue()
                        let tag = Unmanaged<Tag>.fromOpaque(source).takeUnretainedValue()
                        owner.decoded(tag, code, image)
                    }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                    let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
                    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                    let code = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                        decoderSpecification: spec, imageBufferAttributes: attrs, outputCallback: &callback, decompressionSessionOut: &decoder)
                    log.add(["stream": id, "operation": "createDecoder", "status": code, "hardwareRequired": true])
                    try check(code, "create decoder")
                    log.add(["stream": id, "property": "UsingHardwareAcceleratedVideoDecoder",
                             "readback": property(decoder!, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)])
                }
                tag.decodeBegin=benchNow()
                try check(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                    frameRefcon: Unmanaged.passUnretained(tag).toOpaque(), infoFlagsOut: nil), "decode submit")
            } catch {
                lock.lock(); errors.append(String(describing: error)); active.removeValue(forKey: tag.sequence); lock.unlock()
            }
        }
    }
    func decoded(_ tag: Tag, _ code: OSStatus, _ image: CVPixelBuffer?) {
        let end=benchNow(); lock.lock(); defer { active.removeValue(forKey: tag.sequence); lock.unlock() }
        guard code == noErr, let image else { errors.append("decode callback \(code)"); return }
        if tag.measured {
            decoded += 1; decodeMS.append((end-tag.decodeBegin)*1000); roundtripMS.append((end-tag.begin)*1000)
            if id == 0 && tag.sequence % options.fps == options.fps/2 { samples.append((tag.source, image)) }
        }
    }
    func finish() {
        if let encoder { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) }
        queue.sync { if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder) } }
    }
    deinit {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }
}
func distribution(_ values: [Double]) -> [String: Any] {
    let sorted=values.sorted()
    guard !sorted.isEmpty else { return ["count": 0] }
    func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count-1, Int(ceil(Double(sorted.count)*fraction))-1)] }
    return ["count": values.count, "p50": percentile(0.5), "p95": percentile(0.95), "max": sorted.last!,
            "mean": values.reduce(0,+)/Double(values.count)]
}
func cpuSeconds() -> Double {
    var usage=rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000
}
func peakMiB() -> Double { var r=rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_maxrss)/1048576 }
func load() -> [Double] { var values=[Double](repeating:0,count:3); _=getloadavg(&values,3); return values }
func quality(_ original: CVPixelBuffer, _ decoded: CVPixelBuffer, roi: Bool) throws -> Double {
    guard CVPixelBufferGetWidth(original)==CVPixelBufferGetWidth(decoded),
          CVPixelBufferGetHeight(original)==CVPixelBufferGetHeight(decoded), CVPixelBufferGetPlaneCount(decoded)==2
    else { throw Failure(description: "Decoded dimensions/planes mismatch") }
    CVPixelBufferLockBaseAddress(original,.readOnly); CVPixelBufferLockBaseAddress(decoded,.readOnly)
    defer { CVPixelBufferUnlockBaseAddress(original,.readOnly); CVPixelBufferUnlockBaseAddress(decoded,.readOnly) }
    let w=CVPixelBufferGetWidth(original), h=CVPixelBufferGetHeight(original)
    let a=CVPixelBufferGetBaseAddressOfPlane(original,0)!.assumingMemoryBound(to:UInt8.self)
    let b=CVPixelBufferGetBaseAddressOfPlane(decoded,0)!.assumingMemoryBound(to:UInt8.self)
    let sa=CVPixelBufferGetBytesPerRowOfPlane(original,0), sb=CVPixelBufferGetBytesPerRowOfPlane(decoded,0)
    let xs=roi ? 24 : 0, xe=roi ? Int(Double(w)*0.61) : w
    let ys=roi ? 80 : 0, ye=roi ? min(h-20,350) : h
    var sum=0.0
    for y in ys..<ye { for x in xs..<xe { let difference=Double(Int(a[y*sa+x])-Int(b[y*sb+x])); sum += difference*difference } }
    let mse=sum/Double((xe-xs)*(ye-ys))
    return mse==0 ? 99 : 10*log10(255*255/mse)
}
@main enum Benchmark {
    static func main() {
        var output="", report: [String:Any]=["schema":1], log=Log()
        do {
            let o=try Options(); output=o.output; report["configuration"]=o.json
            report["startedAt"]=ISO8601DateFormatter().string(from:Date())
            report["loadAverageBefore"]=load(); report["thermalBefore"]=ProcessInfo.processInfo.thermalState.rawValue
            report["lowPowerMode"]=ProcessInfo.processInfo.isLowPowerModeEnabled
            let engines=try (0..<o.streams).map { try Codec(o,$0,log) }
            let pixels=try Pixels(o.width,o.height)
            var sources:[Source]=[]
            for frame in 0..<(o.pattern=="static" ? 1 : 60) {
                try autoreleasepool {
                    let (bgra,image)=try pixels.render(frame,o.pattern)
                    sources.append(Source(pixels:try pixels.convert(bgra,to:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),jpeg:try pixels.jpeg(image)))
                }
            }
            report["fixtureReadyPeakMiB"]=peakMiB()
            var preMS:[Double]=[], scheduleMS:[Double]=[], sourceBytes=0
            var measureCPU=0.0, measureStart=0.0
            let start=benchNow(), warmFrames=o.warmup*o.fps, total=(o.warmup+o.seconds)*o.fps
            for seq in 0..<total {
                let deadline=start+Double(seq)/Double(o.fps)
                let wait=deadline-benchNow(); if wait>0 { Thread.sleep(forTimeInterval:wait) }
                let measured=seq>=warmFrames
                if seq==warmFrames { measureStart=benchNow(); measureCPU=cpuSeconds() }
                if measured { scheduleMS.append(max(0,benchNow()-deadline)*1000) }
                for engine in engines {
                    if engine.count()>=3 { if measured { engine.rejected += 1 }; continue }
                    try autoreleasepool {
                        let index=(seq+engine.id*17)%sources.count, source=sources[index], begin=benchNow()
                        let input = o.input=="jpeg" ? try pixels.decodeJPEG(source.jpeg) : source.pixels
                        if measured { preMS.append((benchNow()-begin)*1000); sourceBytes += source.jpeg.count }
                        engine.submit(input,source:index,sequence:seq,begin:begin,measured:measured)
                    }
                }
            }
            for engine in engines { engine.finish() }
            // Keep the denominator at the requested real-time interval if the last frame completes early.
            let finalDeadline=start+Double(o.warmup+o.seconds)
            if benchNow()<finalDeadline { Thread.sleep(forTimeInterval:finalDeadline-benchNow()) }
            let wall=benchNow()-measureStart, cpu=cpuSeconds()-measureCPU
            let encoded=engines.reduce(0){$0+$1.encoded}, decoded=engines.reduce(0){$0+$1.decoded}
            let errors=engines.flatMap(\.errors), pending=engines.reduce(0){$0+$1.count()}
            let bytes=engines.reduce(0){$0+$1.bytes}
            report["status"]=errors.isEmpty && pending==0 && decoded==encoded && decoded>0 ? "ok" : "error"
            report["errors"]=errors; report["pendingFrames"]=pending
            report["measurementWallSeconds"]=wall; report["requestedFrames"]=o.seconds*o.fps*o.streams
            report["encodedFrames"]=encoded; report["decodedFrames"]=decoded
            report["admissionDrops"]=engines.reduce(0){$0+$1.rejected}; report["encoderDrops"]=engines.reduce(0){$0+$1.dropped}
            report["keyframes"]=engines.reduce(0){$0+$1.keyframes}
            report["payloadBytes"]=bytes; report["actualMbpsTotal"]=Double(bytes)*8/wall/1_000_000
            report["completedFPSPerStream"]=Double(decoded)/wall/Double(o.streams)
            report["jpegCorpusMbpsForAdmittedFrames"]=Double(sourceBytes)*8/wall/1_000_000
            report["encodeMS"]=distribution(engines.flatMap(\.encodeMS)); report["decodeMS"]=distribution(engines.flatMap(\.decodeMS))
            report["localRoundtripMS"]=distribution(engines.flatMap(\.roundtripMS)); report["encodeSubmitMS"]=distribution(engines.flatMap(\.submitMS))
            report["inputPreparationMS"]=distribution(preMS); report["scheduleLatenessMS"]=distribution(scheduleMS)
            report["processCPUPercentOneCore100"]=100*cpu/wall; report["peakRSSMiB"]=peakMiB()
            report["thermalAfter"]=ProcessInfo.processInfo.thermalState.rawValue; report["loadAverageAfter"]=load()
            var psnr:[Double]=[], textPSNR:[Double]=[], jpegPSNR:[Double]=[]
            for (index,image) in engines[0].samples {
                psnr.append(try quality(sources[index].pixels,image,roi:false))
                textPSNR.append(try quality(sources[index].pixels,image,roi:true))
                if o.input=="jpeg" { jpegPSNR.append(try quality(sources[index].pixels,pixels.decodeJPEG(sources[index].jpeg),roi:true)) }
            }
            report["sampledLumaPSNRdB"]=distribution(psnr); report["sampledTextLumaPSNRdB"]=distribution(textPSNR)
            report["jpegInputTextLumaPSNRdB"]=distribution(jpegPSNR)
            if o.images, let (index,image)=engines[0].samples.last {
                try pixels.save(sources[index].pixels,output+".source.png"); try pixels.save(image,output+".decoded.png")
                if o.input=="jpeg" { try pixels.save(pixels.decodeJPEG(sources[index].jpeg),output+".jpeg-input.png") }
            }
        } catch { report["status"]="error"; report["error"]=String(describing:error) }
        report["events"]=log.events
        do {
            let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            if !output.isEmpty { try data.write(to:URL(fileURLWithPath:output),options:.atomic) }
            print(String(decoding:data,as:UTF8.self))
        } catch { fputs("Cannot write result: \(error)\n",stderr); exit(2) }
        if report["status"] as? String != "ok" { exit(1) }
    }
}
