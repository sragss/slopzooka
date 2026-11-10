import Foundation

// The live probe's existing length-prefixed framing, restricted to independent
// JPEG frames. Production video codec selection is outside this experiment.
struct ProbeMediaHeader: Decodable {
    let kind: String
    let generation: Int
    var sequence: Int? = nil
    var reason: String? = nil
}
struct ProbeMediaParser {
    private var bytes = Data()
    mutating func append(_ data: Data) throws -> [(ProbeMediaHeader, Data)] {
        guard bytes.count + data.count <= 17 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        bytes.append(data)
        var result: [(ProbeMediaHeader, Data)] = []
        while bytes.count >= 8 {
            let prefix = Array(bytes.prefix(8))
            func size(_ offset: Int) -> Int { prefix[offset..<offset+4].reduce(0) { $0 << 8 | Int($1) } }
            let m = size(0), n = size(4)
            guard m > 0, m <= 65536, n <= 8 * 1024 * 1024 else { throw URLError(.cannotParseResponse) }
            guard bytes.count >= 8 + m + n else { break }
            let normalized = Data(bytes)
            let header = try JSONDecoder().decode(ProbeMediaHeader.self, from: normalized.subdata(in: 8..<8+m))
            guard ["jpeg", "status", "paused"].contains(header.kind) else { throw URLError(.cannotDecodeContentData) }
            result.append((header, normalized.subdata(in: 8+m..<8+m+n)))
            bytes = Data(normalized.dropFirst(8+m+n))
        }
        return result
    }
}
