import Foundation

/// Per viewer, owned by its native connection queue. One stalled subscriber
/// cannot consume another subscriber's credit or reset its decoder.
nonisolated struct VideoSendWindow {
    static let frameLimit = 2
    static let acknowledgementDeadline: TimeInterval = 1
    let streamID: UUID
    private var pending: [(sequence: UInt64, sent: TimeInterval)] = []
    private var lastOffered: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    private(set) var needsKeyframe = true
    var outstandingFrames: Int { pending.count }
    init(streamID: UUID) { self.streamID = streamID }

    mutating func offer(_ header: VideoHeader, now: TimeInterval, writable: Bool) throws -> Bool {
        try checkDeadline(now: now)
        guard header.kind == .h264, header.streamID == streamID, header.sequence > lastOffered else { throw VideoFailure.invalidPacket }
        if lastOffered != 0 && header.sequence != lastOffered + 1 { needsKeyframe = true }
        lastOffered = header.sequence
        guard writable, pending.count < Self.frameLimit else { needsKeyframe = true; return false }
        guard !needsKeyframe || header.keyframe else { return false }
        needsKeyframe = false
        pending.append((header.sequence, now))
        return true
    }
    mutating func acknowledge(_ header: VideoHeader) throws {
        guard header.kind == .acknowledgement, header.streamID == streamID else { throw VideoFailure.invalidAcknowledgement }
        // Repeated ACKs are harmless. An unsent/future sequence cannot grant credit.
        if header.sequence <= lastAcknowledged { return }
        guard pending.contains(where: { $0.sequence == header.sequence }) else { throw VideoFailure.invalidAcknowledgement }
        pending.removeAll { $0.sequence <= header.sequence }
        lastAcknowledged = header.sequence
    }
    func checkDeadline(now: TimeInterval) throws {
        if let first = pending.first, now - first.sent >= Self.acknowledgementDeadline { throw VideoFailure.stalled }
    }
}

/// Receive-side dependency and inactivity checks precede decoder enqueue. A
/// suspended renderer must reconnect rather than display an old buffered burst.
nonisolated struct VideoReceiveWindow {
    static let inactivityDeadline: TimeInterval = 1.5
    let streamID: UUID
    private var lastSequence: UInt64 = 0
    private var formatID: UInt64 = 0
    private var lastDrain: TimeInterval
    private(set) var needsKeyframe = true
    init(streamID: UUID, now: TimeInterval) { self.streamID = streamID; lastDrain = now }

    mutating func receive(_ packet: VideoPacket, now: TimeInterval) throws -> Bool {
        guard now - lastDrain < Self.inactivityDeadline else { throw VideoFailure.stalled }
        lastDrain = now
        let header = packet.header
        guard header.streamID == streamID else { throw VideoFailure.invalidPacket }
        try header.validate(payloadBytes: packet.payload.count)
        if header.kind == .state {
            if header.state != .idle { needsKeyframe = true }
            return false
        }
        guard header.kind == .h264, header.sequence > lastSequence else { throw VideoFailure.invalidPacket }
        if header.formatID != formatID || (lastSequence != 0 && header.sequence != lastSequence + 1) { needsKeyframe = true }
        lastSequence = header.sequence
        guard !needsKeyframe || header.keyframe else { return false }
        formatID = header.formatID
        needsKeyframe = false
        return true
    }
    func checkDeadline(now: TimeInterval) throws {
        if now - lastDrain >= Self.inactivityDeadline { throw VideoFailure.stalled }
    }
}
