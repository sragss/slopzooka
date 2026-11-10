import Foundation
import Network

// Configure callbacks before start, then access state exclusively on linkQueue.
// The unchecked conformance permits the UI to transfer this queue-owned object.
final class LinkClient: @unchecked Sendable {
    var event: (([String: Any]) -> Void)?
    var complete: ((Bool) -> Void)?
    private let config: LinkConfig
    private let peer: Bool
    private let condition: String
    private var browser: NWBrowser?
    private var channel: Channel?
    private var endpoint: NWEndpoint?
    private var running = false
    private var attempt = 0, phase = 0
    private var started = 0.0, connecting = 0.0, phaseStart = 0.0, lastFrame = 0.0
    private var bytes = 0, frames = 0, lastSequence: UInt64 = 0, pingID: UInt64 = 0
    private var pings: [UInt64: Double] = [:]
    private var rtts: [Double] = [], gaps: [Double] = []
    private var results: [[String: Any]] = [], paths: [[String: Any]] = []
    private var pingTimer: DispatchSourceTimer?
    private var awaitingSave = false
    init(config: LinkConfig, peer: Bool, condition: String) {
        self.config = config; self.peer = peer; self.condition = condition
    }
    func start(direct: NWEndpoint? = nil) {
        dispatchPrecondition(condition: .onQueue(linkQueue))
        running = true; started = clockNow()
        emit(["event": "start", "peerEnabled": peer, "condition": condition,
              "os": ProcessInfo.processInfo.operatingSystemVersionString])
        if let direct { endpoint = direct; connect(); return }
        let p = NWParameters(); p.includePeerToPeer = peer
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: p)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.fail("discovery: \(error)") }
        }
        browser.browseResultsChangedHandler = { [weak self] values, _ in
            guard let self, self.running, self.endpoint == nil else { return }
            for result in values {
                if case .service(let name, _, _, _) = result.endpoint, name == self.config.service {
                    self.emit(["event": "discovered", "milliseconds": (clockNow() - self.started) * 1000,
                               "endpoint": String(describing: result.endpoint),
                               "interfaces": result.interfaces.map { $0.name }])
                    // Resolve the Bonjour service, not an infrastructure IPv4 literal.
                    self.endpoint = result.endpoint; self.connect(); return
                }
            }
        }
        browser.start(queue: linkQueue)
        linkQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let self, self.running, self.endpoint == nil { self.fail("discovery timeout") }
        }
    }
    func cancel() { dispatchPrecondition(condition: .onQueue(linkQueue)); fail("cancelled") }
    private func connect() {
        guard running, let endpoint else { return }
        connecting = clockNow()
        do {
            let c = Channel(NWConnection(to: endpoint, using: try parameters(config, peer: peer)))
            channel = c
            c.onReady = { [weak self, weak c] in
                guard let self else { return }
                c?.send(Packet(kind: .auth, body: Data(self.config.token.utf8)))
            }
            c.onPath = { [weak self] path in
                guard let self else { return }
                self.paths.append(path); self.emit(["event": "client_path", "attempt": self.attempt, "path": path])
            }
            c.onPacket = { [weak self] packet in self?.receive(packet) }
            c.onClose = { [weak self, weak c] reason in
                guard let self, self.channel === c else { return }
                self.fail(reason)
            }
            c.start()
            linkQueue.asyncAfter(deadline: .now() + 12) { [weak self, weak c] in
                guard let self, self.running, self.channel === c, self.pingTimer == nil else { return }
                self.fail("connect/authentication timeout")
            }
        } catch { fail("configuration: \(error)") }
    }
    private func receive(_ packet: Packet) {
        guard running else { return }
        switch packet.kind {
        case .ready:
            guard pingTimer == nil, (object(packet.body)["peerEnabled"] as? Bool) == peer else { fail("host mode mismatch / duplicate ready"); return }
            emit(["event": "authenticated", "attempt": attempt, "milliseconds": (clockNow() - connecting) * 1000,
                  "host": object(packet.body)])
            let timer = DispatchSource.makeTimerSource(queue: linkQueue); pingTimer = timer
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.ping() }; timer.resume()
            beginPhase(attempt == 0 ? 0 : 1)
        case .pong:
            if let sent = pings.removeValue(forKey: packet.sequence) { rtts.append((clockNow() - sent) * 1000) }
        case .frame:
            let expected = [0, 33333, 100000][phase]
            guard expected > 0, packet.body.count == expected,
                  packet.body == Data(repeating: 0xa5, count: expected), packet.sequence > lastSequence else {
                fail("payload/sequence mismatch"); return
            }
            let now = clockNow()
            if frames == 0 {
                emit(["event": "first_payload", "attempt": attempt, "phase": phase,
                      "sinceConnectMs": (now - connecting) * 1000, "sincePhaseMs": (now - phaseStart) * 1000])
            } else { gaps.append((now - lastFrame) * 1000) }
            lastFrame = now; lastSequence = packet.sequence; frames += 1; bytes += packet.body.count
        case .end:
            guard packet.sequence == UInt64(phase), pingTimer != nil else { fail("unexpected phase end"); return }
            let elapsed = clockNow() - phaseStart
            let row: [String: Any] = ["attempt": attempt, "phase": phase, "targetMbps": [0, 8, 24][phase],
                "receivedPayloadMbps": Double(bytes) * 8 / elapsed / 1_000_000, "receiverSeconds": elapsed,
                "receivedFrames": frames, "rttSamples": rtts.count, "rttP50Ms": percentile(rtts, 0.5),
                "rttP95Ms": percentile(rtts, 0.95), "rttMaxMs": rtts.max() ?? 0,
                "frameGapP95Ms": percentile(gaps, 0.95), "frameGapMaxMs": gaps.max() ?? 0,
                "host": object(packet.body)]
            results.append(row); emit(["event": "phase_result", "result": row])
            guard rtts.count >= 5, phase == 0 || frames > 0 else { fail("insufficient received samples"); return }
            guard (object(packet.body)["sent"] as? Int) == frames else { fail("host/receiver frame count mismatch"); return }
            if attempt == 0 && phase < 2 { beginPhase(phase + 1) }
            else if attempt == 0 {
                emit(["event": "deliberate_reconnect"])
                pingTimer?.cancel(); pingTimer = nil
                let old = channel; channel = nil; old?.close("deliberate reconnect")
                attempt = 1; connect()
            } else {
                pingTimer?.cancel(); pingTimer = nil; awaitingSave = true
                let report: [String: Any] = ["condition": condition, "peerEnabled": peer,
                    "scope": "synthetic TLS/TCP link; not rendered video or proof of direct radio",
                    "elapsed": clockNow() - started, "results": results, "clientPaths": paths]
                emit(["event": "report", "report": report])
                channel?.send(Packet(kind: .report, body: json(report)))
                linkQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if let self, self.running, self.awaitingSave { self.fail("host report acknowledgement timeout") }
                }
            }
        case .saved:
            guard awaitingSave else { fail("unexpected report acknowledgement"); return }
            emit(["event": "completed", "hostSaved": true]); stop(); complete?(true)
        default: fail("unexpected message")
        }
    }
    private func beginPhase(_ number: Int) {
        phase = number; phaseStart = clockNow(); lastFrame = 0; frames = 0; bytes = 0; lastSequence = 0
        rtts = []; gaps = []; pings = [:]
        emit(["event": "phase", "attempt": attempt, "targetMbps": [0, 8, 24][phase]])
        channel?.send(Packet(kind: .phase, sequence: UInt64(phase)))
        let current = channel, currentAttempt = attempt
        linkQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak current] in
            if let self, self.running, self.channel === current, self.attempt == currentAttempt,
               self.phase == number, !self.awaitingSave { self.fail("phase deadline") }
        }
    }
    private func ping() {
        guard pings.count < 30 else { fail("pong stalled over 3s"); return }
        pingID += 1; pings[pingID] = clockNow()
        channel?.send(Packet(kind: .ping, sequence: pingID))
    }
    private func emit(_ entry: [String: Any]) {
        var entry = entry; entry["elapsed"] = clockNow() - started; event?(entry)
    }
    private func fail(_ reason: String) {
        guard running else { return }
        emit(["event": "failed", "reason": reason, "partialResults": results]); stop(); complete?(false)
    }
    private func stop() {
        running = false; browser?.cancel(); browser = nil; pingTimer?.cancel(); pingTimer = nil
        let old = channel; channel = nil; old?.close("client done")
    }
}
