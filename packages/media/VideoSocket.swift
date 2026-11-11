import Foundation
import Network

nonisolated enum VideoDisconnect: String, Sendable {
    case connection, stalled, unavailable, invalidMedia, renderer, ended
    var retryable: Bool { self != .unavailable && self != .invalidMedia }
    var message: String {
        switch self {
        case .connection: return "Connection interrupted."
        case .stalled: return "Stream stalled."
        case .unavailable: return "Mac window unavailable. Check permissions, unlock the Mac, or select the window again."
        case .invalidMedia: return "Invalid video stream. Reload to reconnect."
        case .renderer: return "The renderer could not keep up."
        case .ended: return "Stream ended."
        }
    }
}

/// Reads through the accepted companion route. Receive is deliberately paused
/// while the renderer consumes a bounded batch; ACK means enqueue, not display.
nonisolated final class VideoSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "slz.video-receive")
    private let connection: NWConnection
    private let request: Data
    private let consume: @Sendable ([VideoPacket], TimeInterval, @escaping @Sendable (Bool) -> Void) -> Void
    private let ended: @Sendable (VideoDisconnect) -> Void
    private var parser = VideoPacketParser()
    private var response = Data()
    private var upgraded = false
    private var stopped = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?
    init(connection: NWConnection, request: Data,
         consume: @escaping @Sendable ([VideoPacket], TimeInterval, @escaping @Sendable (Bool) -> Void) -> Void,
         ended: @escaping @Sendable (VideoDisconnect) -> Void) {
        self.connection = connection; self.request = request; self.consume = consume; self.ended = ended
    }
    func start() {
        queue.async {
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.finish(.connection) } else { self.receive() }
                    })
                } else if case .failed = state { self.finish(.connection) }
            }
            self.connection.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.timer = timer
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastActivity > (self.upgraded ? 1.5 : 10) { self.finish(.stalled) }
            }
            timer.resume()
        }
    }
    func stop() { queue.async { self.finish(nil) } }
    private func receive() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, eof, error in
            guard let self, !self.stopped else { return }
            do {
                var bytes = data ?? Data()
                if !self.upgraded {
                    self.response.append(bytes)
                    guard self.response.count <= 80 * 1024 else { throw VideoFailure.oversizedPacket }
                    guard let range = self.response.range(of: Data("\r\n\r\n".utf8)) else {
                        guard self.response.count <= 8192, !eof, error == nil else { throw VideoFailure.invalidPacket }
                        self.receive(); return
                    }
                    guard range.lowerBound < 8192,
                          let text = String(data: self.response.prefix(upTo: range.lowerBound), encoding: .utf8),
                          text.hasPrefix("HTTP/1.1 101 "), text.lowercased().contains("upgrade: slz-window-v1") else {
                        self.finish(.unavailable); return
                    }
                    bytes = Data(self.response.suffix(from: range.upperBound)); self.response.removeAll(); self.upgraded = true
                    self.lastActivity = ProcessInfo.processInfo.systemUptime
                }
                var batch: [VideoPacket] = []
                try self.parser.append(bytes) { packet in
                    guard batch.count < 8 else { throw VideoFailure.oversizedPacket }
                    batch.append(packet)
                }
                guard !batch.isEmpty else {
                    if eof || error != nil { self.finish(.ended) } else { self.receive() }
                    return
                }
                let packets = batch
                self.consume(packets, self.lastActivity + 1.5) { [weak self] accepted in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.stopped else { return }
                        guard accepted else { self.finish(.renderer); return }
                        // A suspended renderer cannot keep an old connection alive by
                        // releasing buffered ACKs after the finite receive deadline.
                        guard ProcessInfo.processInfo.systemUptime - self.lastActivity < 1.5 else { self.finish(.stalled); return }
                        self.lastActivity = ProcessInfo.processInfo.systemUptime
                        for packet in packets where packet.header.kind == .h264 || packet.header.kind == .state {
                            let header = VideoHeader(kind: packet.header.kind == .state ? .stateAcknowledgement : .acknowledgement, streamID: packet.header.streamID, sequence: packet.header.sequence)
                            if let ack = try? VideoPacket(header: header).encoded() {
                                self.connection.send(content: ack, completion: .contentProcessed { [weak self] error in
                                    if error != nil { self?.finish(.connection) }
                                })
                            }
                        }
                        if eof || error != nil { self.finish(.ended) } else { self.receive() }
                    }
                }
            } catch { self.finish(.invalidMedia) }
        }
    }
    private func finish(_ reason: VideoDisconnect?) {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let reason { ended(reason) }
    }
}
