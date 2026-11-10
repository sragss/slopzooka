import Foundation
import Darwin

struct ProbeFailure: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "\(code): \(message)" }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

// Every packet is length-prefixed. JSON metadata and binary media have separate limits.
// The HTTP transport strips chunk framing before these bytes reach the parser.
struct MediaHeader: Codable {
    var kind: String
    var generation: Int
    var sequence: Int = 0
    var timestamp: Double = 0
    var width: Int = 0
    var height: Int = 0
    var keyframe: Bool = false
    var parameterSets: [Data] = []
    var reason: String? = nil
}
struct MediaPacket {
    var header: MediaHeader
    var payload = Data()
    func encoded() throws -> Data {
        let meta = try JSONEncoder().encode(header)
        guard meta.count <= 65536, payload.count <= 8 * 1024 * 1024 else {
            throw ProbeFailure("packet_too_large", "Media packet exceeds the prototype limit")
        }
        var data = Data()
        for value in [meta.count, payload.count] {
            var n = UInt32(value).bigEndian
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        }
        data.append(meta); data.append(payload)
        return data
    }
}
struct PacketParser {
    private var buffer = Data()
    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
    mutating func append(_ bytes: Data) throws -> [MediaPacket] {
        guard buffer.count + bytes.count <= 17 * 1024 * 1024 else {
            throw ProbeFailure("buffer_limit", "Receiver buffer limit exceeded")
        }
        buffer.append(bytes)
        var packets: [MediaPacket] = []
        while buffer.count >= 8 {
            let prefix = Array(buffer.prefix(8))
            func number(_ i: Int) -> Int {
                prefix[i..<i+4].reduce(0) { ($0 << 8) | Int($1) }
            }
            let m = number(0), p = number(4)
            guard m > 0, m <= 65536, p <= 8 * 1024 * 1024 else {
                throw ProbeFailure("invalid_frame", "Invalid media lengths")
            }
            let total = 8 + m + p
            guard buffer.count >= total else { break }
            let data = Data(buffer)
            let h = try JSONDecoder().decode(MediaHeader.self, from: data.subdata(in: 8..<8+m))
            packets.append(MediaPacket(header: h, payload: data.subdata(in: 8+m..<total)))
            buffer = Data(data.dropFirst(total))
        }
        return packets
    }
}

struct Command: Codable {
    var action: String
    var generation: Int?
    var target: String?
    var windowID: UInt32?
    var observation: String?
    var element: String?
    var text: String?
    var width: Double?
    var height: Double?
    var udid: String?
    var url: String?
    var seconds: Double?
}

struct Gate {
    private(set) var desktop = "unknown"
    private(set) var source = "startup"
    private(set) var generation = 1
    private(set) var armed = false
    private(set) var expires: Double = 0
    private(set) var lastSignal: Double = 0
    mutating func arm(seconds: Double, now: Double) throws {
        guard seconds.isFinite, seconds == 0 || (seconds >= 30 && seconds <= 7200) else {
            throw ProbeFailure("invalid_duration", "Choose 30–7200 seconds, or zero for explicit manual stop")
        }
        armed = true; expires = seconds == 0 ? .infinity : now + seconds; generation += 1
        desktop = "unknown"; source = "armed"; lastSignal = now
    }
    mutating func stop() { armed = false; generation += 1 }
    mutating func invalidate() { generation += 1 }
    @discardableResult mutating func update(_ state: String, source: String, now: Double) -> Bool {
        let changed = desktop != state
        desktop = state; self.source = source; lastSignal = now
        if changed { generation += 1 }
        return changed
    }
    func checkRun(now: Double) throws {
        guard armed, now < expires else { throw ProbeFailure("not_armed", "The experiment is stopped or its deadline expired") }
    }
    func checkDesktop(expected: Int?, now: Double) throws {
        try checkRun(now: now)
        guard desktop == "unlocked" else {
            throw ProbeFailure("desktop_\(desktop)", "Desktop capture/input unavailable; independently probe device capabilities")
        }
        guard expected == generation else { throw ProbeFailure("stale_generation", "Refresh status and observation before acting") }
    }
}

private let continuousTimeScale: Double = {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()
// Includes sleep: waking the Mac cannot silently extend an agreed test slot.
func uptime() -> Double { Double(mach_continuous_time()) * continuousTimeScale }
func jsonData(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
