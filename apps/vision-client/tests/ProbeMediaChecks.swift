import Foundation

@main struct ProbeMediaChecks {
    static func main() throws {
        func frame(_ header: String, _ payload: Data) -> Data {
            let meta = Data(header.utf8)
            var result = Data()
            for value in [meta.count, payload.count] {
                var n = UInt32(value).bigEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) }
            }
            result.append(meta); result.append(payload); return result
        }
        let image = Data([255, 216, 1, 2, 255, 217])
        let first = frame("{\"kind\":\"jpeg\",\"generation\":1,\"sequence\":2}", image)
        let paused = frame("{\"kind\":\"paused\",\"generation\":2,\"reason\":\"replaced\"}", Data())
        var parser = ProbeMediaParser(), decoded: [(ProbeMediaHeader, Data)] = []
        for byte in first + paused { decoded += try parser.append(Data([byte])) }
        precondition(decoded.count == 2 && decoded[0].1 == image && decoded[1].0.generation == 2)
        var bad = ProbeMediaParser()
        do { _ = try bad.append(Data([0, 0, 0, 1, 255, 255, 255, 255])); preconditionFailure("Oversized image accepted") } catch {}
        var unsupported = ProbeMediaParser()
        do { _ = try unsupported.append(frame("{\"kind\":\"unknown\",\"generation\":1}", Data())); preconditionFailure("Unknown media accepted") } catch {}
        print("PASS: live JPEG receiver framing survives fragmentation, source replacement and rejects oversized/unsupported packets")
    }
}
