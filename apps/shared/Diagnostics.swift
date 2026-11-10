import Foundation
import Combine
import CryptoKit
import os

/// Native facade shared by visionOS and the Mac menu app. Fields are metadata,
/// never terminal contents, transcripts, request bodies, or credentials.
@MainActor
struct AppLog {
    private let component: String
    private let fields: [String: String]
    private let diagnostics: NativeDiagnostics
    init(_ component: String, fields: [String: String] = [:], diagnostics: NativeDiagnostics? = nil) {
        self.component = component
        self.fields = fields
        self.diagnostics = diagnostics ?? .shared
    }
    func child(_ fields: [String: String]) -> Self {
        Self(component, fields: self.fields.merging(fields) { _, new in new }, diagnostics: diagnostics)
    }
    func info(_ event: String, _ fields: [String: String] = [:]) { write("info", event, fields) }
    func warn(_ event: String, _ fields: [String: String] = [:]) { write("warn", event, fields) }
    func operation<T>(_ event: String, _ fields: [String: String] = [:], run: @MainActor () async throws -> T) async rethrows -> T
    {
        try await DiagnosticContext.$actionID.withValue(DiagnosticContext.actionID ?? UUID().uuidString) {
            let log = child(fields)
            let start = ProcessInfo.processInfo.systemUptime
            log.info("\(event).started")
            do {
                let result = try await run()
                log.info(
                    "\(event).completed", ["durationMs": String((ProcessInfo.processInfo.systemUptime - start) * 1000)])
                return result
            } catch {
                let fields = ["durationMs": String((ProcessInfo.processInfo.systemUptime - start) * 1000)]
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    log.info("\(event).cancelled", fields)
                } else {
                    log.error("\(event).failed", error: error, fields)
                }
                throw error
            }
        }
    }
    func error(_ event: String, error: Error? = nil, _ fields: [String: String] = [:]) {
        write("error", event, fields, error: error)
    }
    private func write(_ level: String, _ event: String, _ fields: [String: String], error: Error? = nil) {
        var values = self.fields.merging(fields) { _, new in new }
        if let actionID = DiagnosticContext.actionID { values["actionId"] = actionID }
        diagnostics.record(event, component: component, level: level, fields: values, error: error)
    }
}

enum DiagnosticContext {
    @TaskLocal static var actionID: String?
}

@MainActor
final class NativeDiagnostics: ObservableObject {
    static let shared = NativeDiagnostics()
    struct Entry {
        let id: String
        var hostID: String?
        let data: Data
        let createdAt: Date
    }
    @Published private(set) var recentEntries: [String] = []
    private let logger = Logger(subsystem: "com.samragsdale.SlopZooka", category: "diagnostics")
    private let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let instanceID = UUID().uuidString
    private var sequence = 0
    private var pending: [Entry] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var source = "vision-client"
    private var activeHostID: String?
    private var clocks: [String: [String: Any]] = [:]
    private static let buildID: String = Bundle.main.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unknown"
    private static let correlationKeys = ["hostId", "clientId", "actionId", "requestId", "sessionId", "workspaceId", "windowId", "commandId", "connectionId"]
    private var localFile: NativeLogFile?
    private var writing = false
    private var byteLimit: Int
    init(byteLimit: Int = 8 * 1024 * 1024) { self.byteLimit = byteLimit }

    var pendingCount: Int { pending.count }

    func record(_ event: String, component: String = "app", level: String = "info", fields: [String: String] = [:], error: Error? = nil) {
        sequence += 1
        var values = fields
        let destination = fields["hostId"].flatMap { $0.isEmpty ? nil : $0 } ?? activeHostID
        if dropped > 0 {
            values["droppedBefore"] = String(dropped)
            dropped = 0
        }
        var metadata: [String: Any] = [:]
        for key in values.keys.sorted().prefix(24) { metadata[String(key.prefix(80))] = Self.safeField(key, values[key]!) }
        for key in Self.correlationKeys where values[key] != nil { metadata[key] = String(values[key]!.prefix(120)) }
        if let error { metadata["error"] = Self.errorDetails(error) }
        var object: [String: Any] = [
            "version": 1, "source": source, "instanceId": instanceID, "sequence": sequence,
            "ts": timestamp.string(from: Date()), "monotonicMs": ProcessInfo.processInfo.systemUptime * 1000,
            "level": level, "component": String(decoding: component.utf16.prefix(120), as: UTF16.self),
            "event": String(decoding: event.utf16.prefix(160), as: UTF16.self),
            "buildId": Self.buildID,
            "runtimeId": "os-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)",
            "fields": metadata,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object), data.count > 8192 {
            var bounded = metadata.filter { Self.correlationKeys.contains($0.key) }
            bounded["truncated"] = true
            if let error { bounded["error"] = ["message": String(Self.safeText(error.localizedDescription).prefix(256))] }
            object["fields"] = bounded
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= 8192 else {
            dropped += 1
            return
        }
        enqueue(data, id: "\(instanceID):\(sequence)", hostID: destination)
        let message = values["message"].map { " \($0)" } ?? ""
        let line = "\(timestamp.string(from: Date())) [\(component)] \(Self.safeText(event + message))"
        recentEntries.append(line)
        if recentEntries.count > 120 { recentEntries.removeFirst(recentEntries.count - 120) }
        logger.log("\(line, privacy: .public)")
    }

    /// Browser identity/timestamps survive the native hop. Only the first-party
    /// main document can call this; the WebView adapter validates origin and frame.
    func receiveBrowserEvent(_ object: Any, hostID: String?) {
        // The collector validates the protocol. This hop only bounds opaque JSON;
        // local receipt IDs let it acknowledge even malformed records once rejected.
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= 8192
        else {
            dropped += 1
            return
        }
        enqueue(data, id: UUID().uuidString, hostID: hostID ?? activeHostID)
    }

    private func enqueue(_ data: Data, id: String, hostID: String?) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        while let first = pending.first, pendingBytes + data.count > byteLimit || first.createdAt < cutoff {
            pendingBytes -= pending.removeFirst().data.count
            dropped += 1
        }
        guard data.count <= byteLimit else {
            dropped += 1
            return
        }
        pending.append(Entry(id: id, hostID: hostID, data: data, createdAt: Date()))
        pendingBytes += data.count
        if localFile != nil && !writing {
            writing = true
            Task(priority: .utility) { await drainLocal() }
        }
    }

    func bind(to hostID: String) {
        activeHostID = hostID
        // Pre-pairing device events acquire a destination once. Switching Macs
        // never reassigns events already associated with another host.
        for index in pending.indices where pending[index].hostID == nil { pending[index].hostID = hostID }
    }
    func calibrate(hostID: String, serverTime: String?, durationMs: Double) {
        guard let serverTime, let server = timestamp.date(from: serverTime), durationMs.isFinite, durationMs >= 0 else { return }
        clocks[hostID] = [
            "observedAt": timestamp.string(from: Date()),
            "offsetMs": server.timeIntervalSinceNow * 1000 + durationMs / 2,
            "uncertaintyMs": durationMs / 2,
        ]
    }

    func batch(for hostID: String) -> [Entry] {
        var result: [Entry] = []
        var bytes = 0
        for entry in pending where entry.hostID == hostID {
            guard result.count < 32, bytes + entry.data.count <= 48 * 1024 else { break }
            result.append(entry)
            bytes += entry.data.count
        }
        return result
    }
    func acknowledge(_ batch: [Entry]) {
        let ids = Set(batch.map(\.id))
        pending.removeAll { entry in
            guard ids.contains(entry.id) else { return false }
            pendingBytes -= entry.data.count
            return true
        }
    }
    func body(for batch: [Entry]) -> Data {
        var header: [String: Any] = ["version": 1]
        if let hostID = batch.first?.hostID, let clock = clocks[hostID] { header["clock"] = clock }
        var data = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{\"version\":1}".utf8)
        data.removeLast()
        data.append(Data(",\"events\":[".utf8))
        for (index, entry) in batch.enumerated() {
            if index > 0 { data.append(44) }
            data.append(entry.data)
        }
        data.append(Data("]}".utf8))
        return data
    }

    // The menu app explicitly enables disk output; state tests never touch live logs.
    func enableMacLogging() {
        #if os(macOS)
            byteLimit = min(byteLimit, 1024 * 1024)
            source = "mac-menu"
            let home = ProcessInfo.processInfo.environment["SLOPZOOKA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".slopzooka")
            localFile = NativeLogFile(directory: home.appendingPathComponent("logs/mac-menu"))
        #endif
    }
    var logDirectory: URL? { localFile?.directory.deletingLastPathComponent() }
    private func drainLocal() async {
        defer { writing = false }
        guard let localFile else { return }
        while !pending.isEmpty {
            let batch = Array(pending.prefix(32))
            let data = batch.reduce(into: Data()) {
                $0.append($1.data)
                $0.append(10)
            }
            let ok = await localFile.append(data)
            guard ok else { return }
            acknowledge(batch)
        }
    }

    nonisolated private static func safeText(_ value: String) -> String {
        var text = String(value.prefix(2048))
        for (pattern, replacement) in [
            (#"\b(?:https?|wss?)://[^\s\"'<>]+"#, "[url]"),
            (#"(?i)\bBearer\s+[^\s,;]+"#, "Bearer [redacted]"),
            (
                #"(?i)\b(token|ticket|password|secret|api[_ -]?key|credentials?|private[_ -]?key|pairing[ -]?code|authorization)\s*[:=]\s*[^\s,;]+"#,
                "$1=[redacted]"
            ),
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return text
    }
    nonisolated private static func safeField(_ key: String, _ value: String) -> String {
        let privateKey = key.range(
            of: #"(?i)authorization|cookie|token|ticket|password|secret|api[_-]?key|credential|private[_-]?key|pairingCode|transcript|^(text|data|body|environment|payload|command)$"#,
            options: .regularExpression) != nil
        return privateKey ? "[redacted]" : safeText(value)
    }
    nonisolated private static func errorDetails(_ error: Error, depth: Int = 0) -> [String: Any] {
        let native = error as NSError
        var fields: [String: Any] = ["name": safeText(native.domain), "message": safeText(native.localizedDescription), "code": native.code]
        if depth < 2, let cause = native.userInfo[NSUnderlyingErrorKey] as? Error {
            fields["cause"] = errorDetails(cause, depth: depth + 1)
        }
        return fields
    }
}

@MainActor
func slzLog(_ message: String) { NativeDiagnostics.shared.record("app.message", fields: ["message": message]) }
