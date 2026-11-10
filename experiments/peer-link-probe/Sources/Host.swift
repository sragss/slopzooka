import Foundation
import Network

final class LinkHost {
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var channels: [UUID: Channel] = [:]
    let config: LinkConfig
    let peer: Bool
    let log: ([String: Any]) -> Void
    var ready: ((UInt16) -> Void)?
    init(config: LinkConfig, peer: Bool, log: @escaping ([String: Any]) -> Void) {
        self.config = config; self.peer = peer; self.log = log
    }
    func startExcluding(identity: URL, interfaceName: String) {
        let monitor = NWPathMonitor(); self.monitor = monitor
        var resolved = false
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor, !resolved else { return }
            resolved = true; monitor.cancel(); self.monitor = nil
            guard let interface = path.availableInterfaces.first(where: { $0.name == interfaceName }) else {
                self.log(["event": "exclusion_failed", "reason": "interface unavailable", "name": interfaceName]); exit(2)
            }
            self.log(["event": "interface_excluded", "name": interface.name, "type": String(describing: interface.type)])
            do { try self.start(identity: identity, excluding: [interface]) }
            catch { self.log(["event": "listener_failed", "reason": String(describing: error)]); exit(2) }
        }
        monitor.start(queue: linkQueue)
        linkQueue.asyncAfter(deadline: .now() + 3) {
            if !resolved { print("Interface lookup timed out"); exit(2) }
        }
    }
    func start(identity: URL, loopback: Bool = false, excluding: [NWInterface] = []) throws {
        let p = try parameters(config, peer: peer, identityURL: identity)
        p.prohibitedInterfaces = excluding
        if loopback { p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: p)
        if !loopback { listener.service = NWListener.Service(name: config.service, type: serviceType) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.log(["event": "listener", "state": String(describing: state), "peerEnabled": self.peer])
            if case .ready = state, let port = listener.port { self.ready?(port.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: linkQueue)
    }
    func stop() { listener?.cancel(); for c in Array(channels.values) { c.close("host stop") }; channels.removeAll() }
    private func accept(_ connection: NWConnection) {
        guard channels.count < 4 else { connection.cancel(); return }
        let id = UUID(), channel = Channel(connection)
        channels[id] = channel
        var authorized = false, busy = false, active = false
        var phase = -1, tick = 0, sent = 0, skipped = 0
        var timer: DispatchSourceTimer?
        var started = 0.0, busySince = 0.0
        channel.onPath = { [weak self] path in self?.log(["event": "host_path", "connection": id.uuidString, "path": path]) }
        channel.onClose = { [weak self] reason in
            timer?.setEventHandler {}; timer?.cancel(); timer = nil
            self?.channels[id] = nil
            self?.log(["event": "host_closed", "connection": id.uuidString, "reason": reason])
        }
        channel.onPacket = { [weak self, weak channel] packet in
            guard let self, let channel else { return }
            if !authorized {
                guard packet.kind == .auth, packet.body == Data(self.config.token.utf8) else { channel.close("authentication failed"); return }
                authorized = true
                channel.send(Packet(kind: .ready, body: json(["peerEnabled": self.peer, "path": pathInfo(connection.currentPath)])))
                return
            }
            switch packet.kind {
            case .ping: channel.send(Packet(kind: .pong, sequence: packet.sequence))
            case .phase:
                guard !active, packet.sequence <= 2 else { channel.close("invalid phase"); return }
                phase = Int(packet.sequence); tick = 0; sent = 0; skipped = 0; active = true; started = clockNow()
                let bytes = [0, 33333, 100000][phase] // 0, 8, 24 Mbps at 30 Hz, before framing/TLS.
                let duration = phase == 0 ? 2.0 : 5.0
                let source = DispatchSource.makeTimerSource(queue: linkQueue); timer = source
                source.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(1))
                source.setEventHandler { [weak channel] in
                    guard let channel, !channel.closed else { source.setEventHandler {}; source.cancel(); return }
                    if busy && clockNow() - busySince > 2 { channel.close("send stalled over 2s"); return }
                    if clockNow() - started >= duration {
                        source.setEventHandler {}; source.cancel(); timer = nil; active = false
                        channel.send(Packet(kind: .end, sequence: UInt64(phase), body: json([
                            "duration": clockNow() - started, "scheduled": tick, "sent": sent,
                            "skippedBusy": skipped, "payloadBytes": bytes, "path": pathInfo(connection.currentPath)])))
                        return
                    }
                    tick += 1
                    guard bytes > 0 else { return }
                    if busy { skipped += 1; return }
                    busy = true; busySince = clockNow(); sent += 1
                    channel.send(Packet(kind: .frame, sequence: UInt64(tick), body: Data(repeating: 0xa5, count: bytes))) { _ in busy = false }
                }
                source.resume()
            case .report:
                guard !active, !object(packet.body).isEmpty else { channel.close("invalid report"); return }
                self.log(["event": "client_report", "connection": id.uuidString, "report": object(packet.body)])
                channel.send(Packet(kind: .saved))
            default: channel.close("unexpected message")
            }
        }
        channel.start()
        linkQueue.asyncAfter(deadline: .now() + 5) { [weak channel] in if !authorized { channel?.close("authentication deadline") } }
        linkQueue.asyncAfter(deadline: .now() + 90) { [weak channel] in channel?.close("session deadline") }
    }
}
