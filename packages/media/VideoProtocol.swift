import Foundation

nonisolated enum VideoFailure: Error, Equatable {
    case invalidPacket, oversizedPacket, invalidAcknowledgement, stalled
    case codec(stage: String, status: Int32)
}

/// Encoded video stays binary. The small versioned header describes one frame,
/// source state, or acknowledgement; it never carries image bytes as JSON.
nonisolated struct VideoHeader: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case h264, acknowledgement, state, stateAcknowledgement }
    enum State: String, Codable, Sendable { case waiting, idle, locked, permissionRequired, sourceGone, failed }
    var version = 1
    var kind: Kind
    var streamID: UUID
    var sequence: UInt64 = 0
    var formatID: UInt64 = 0
    var width = 0
    var height = 0
    var contentWidth = 0.0
    var contentHeight = 0.0
    var keyframe = false
    var parameterSets: [Data] = []
    var state: State?

    func validate(payloadBytes: Int) throws {
        guard version == 1, payloadBytes <= VideoPacket.maximumPayload else { throw VideoFailure.invalidPacket }
        switch kind {
        case .h264:
            guard sequence > 0, sequence <= UInt64(Int64.max), formatID > 0, payloadBytes > 0,
                  (2...4096).contains(width), (2...4096).contains(height), width * height <= 8_388_608,
                  contentWidth.isFinite, contentHeight.isFinite,
                  (1...16384).contains(contentWidth), (1...16384).contains(contentHeight),
                  state == nil, parameterSets.count == (keyframe ? 2 : 0),
                  parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else { throw VideoFailure.invalidPacket }
        case .acknowledgement:
            guard sequence > 0, payloadBytes == 0, parameterSets.isEmpty, state == nil else { throw VideoFailure.invalidPacket }
        case .stateAcknowledgement:
            guard sequence == 0, payloadBytes == 0, parameterSets.isEmpty, state == nil else { throw VideoFailure.invalidPacket }
        case .state:
            guard state != nil, payloadBytes == 0, parameterSets.isEmpty else { throw VideoFailure.invalidPacket }
        }
    }
}

nonisolated struct VideoPacket: Sendable, Equatable {
    static let maximumHeader = 16 * 1024
    static let maximumPayload = 2 * 1024 * 1024
    static let maximumBytes = 12 + maximumHeader + maximumPayload
    let header: VideoHeader
    var payload = Data()

    func encoded() throws -> Data {
        try header.validate(payloadBytes: payload.count)
        let metadata = try JSONEncoder().encode(header)
        guard metadata.count <= Self.maximumHeader else { throw VideoFailure.oversizedPacket }
        var bytes = Data()
        for value: UInt32 in [0x534C5A56, UInt32(metadata.count), UInt32(payload.count)] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(metadata); bytes.append(payload)
        return bytes
    }
}

/// One bounded incomplete packet, regardless of transport fragmentation. The
/// caller consumes each packet before accepting another input chunk.
nonisolated struct VideoPacketParser {
    private var buffer = Data()
    var bufferedBytes: Int { buffer.count }
    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
    mutating func append(_ chunk: Data, consume: (VideoPacket) throws -> Void) throws {
        var offset = chunk.startIndex
        do {
            while offset < chunk.endIndex {
                let needed: Int
                if buffer.count < 12 { needed = 12 - buffer.count }
                else { needed = try packetSize() - buffer.count }
                let count = min(needed, chunk.distance(from: offset, to: chunk.endIndex))
                let end = chunk.index(offset, offsetBy: count)
                buffer.append(contentsOf: chunk[offset..<end]); offset = end
                guard buffer.count >= 12 else { continue }
                let total = try packetSize()
                guard buffer.count == total else { continue }
                let headerLength = number(at: 4)
                let header = try JSONDecoder().decode(VideoHeader.self, from: buffer.subdata(in: 12..<12 + headerLength))
                let payload = buffer.subdata(in: 12 + headerLength..<total)
                try header.validate(payloadBytes: payload.count)
                buffer.removeAll(keepingCapacity: true)
                try consume(VideoPacket(header: header, payload: payload))
            }
        } catch { reset(); throw error }
    }
    private func number(at offset: Int) -> Int {
        buffer[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    private func packetSize() throws -> Int {
        let header = number(at: 4), payload = number(at: 8)
        guard number(at: 0) == 0x534C5A56, (1...VideoPacket.maximumHeader).contains(header),
              payload <= VideoPacket.maximumPayload else { throw VideoFailure.invalidPacket }
        return 12 + header + payload
    }
}
