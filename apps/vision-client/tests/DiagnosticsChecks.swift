import Foundation
import Combine

@main
struct DiagnosticsChecks {
    @MainActor
    static func main() async throws {
        let log = NativeDiagnostics(byteLimit: 2048)
        log.record("before-pairing", fields: ["token": "native-secret", "url": "https://user:password@host/path?token=private"])
        log.bind(to: "mac-a")
        let first = log.batch(for: "mac-a")
        precondition(first.count == 1)
        let wire = String(decoding: log.body(for: first), as: UTF8.self)
        precondition(!wire.contains("native-secret") && !wire.contains("password") && !wire.contains("token=private"))
        let envelope = try JSONSerialization.jsonObject(with: first[0].data) as! [String: Any]
        precondition(envelope["version"] as? Int == 1 && envelope["source"] as? String == "vision-client")
        precondition(envelope["monotonicMs"] is NSNumber && envelope["sequence"] as? Int == 1)
        log.record("in-flight", fields: ["hostId": "mac-a"])
        log.bind(to: "mac-b")
        log.record("different-mac")
        log.acknowledge(first)
        precondition(log.batch(for: "mac-a").count == 1, "An acknowledgement cannot erase later events")
        precondition(log.batch(for: "mac-b").count == 1, "Switching Macs cannot reassign old events")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        log.receiveBrowserEvent(fixture, hostID: "mac-a")
        let browser = try JSONSerialization.jsonObject(with: log.batch(for: "mac-a").last!.data) as! [String: Any]
        precondition(browser["instanceId"] as? String == "fixture-document" && browser["sequence"] as? Int == 7)
        precondition(browser["ts"] as? String == "2026-11-10T12:00:00.123Z", "The native bridge must preserve source time")
        log.calibrate(hostID: "mac-a", serverTime: "2026-11-10T12:00:00.123Z", durationMs: 10)
        let calibrated = try JSONSerialization.jsonObject(with: log.body(for: log.batch(for: "mac-a"))) as! [String: Any]
        precondition((calibrated["clock"] as? [String: Any])?["uncertaintyMs"] as? Double == 5,
                     "Upload-time calibration must accompany events recorded before calibration")
        let unchanged = log.batch(for: "mac-a").last!.data
        let unchangedEnvelope = try JSONSerialization.jsonObject(with: unchanged) as! NSDictionary
        precondition(unchangedEnvelope == browser as NSDictionary,
                     "Clock calibration must preserve original event identity and timestamps")
        let count = log.pendingCount
        log.receiveBrowserEvent(["malformed": "forward for collector rejection"], hostID: "mac-a")
        precondition(log.pendingCount == count + 1, "Only the collector owns schema validation")
        log.receiveBrowserEvent(["oversized": String(repeating: "x", count: 9000)], hostID: "mac-a")
        precondition(log.pendingCount == count + 1, "The opaque bridge still enforces its byte cap")
        for index in 0..<50 { log.record("bounded", fields: ["index": String(index)]) }
        precondition(log.pendingCount < 10)
        precondition(String(decoding: log.body(for: log.batch(for: "mac-b")), as: UTF8.self).contains("droppedBefore"))

        let errors = NativeDiagnostics()
        let cause = NSError(domain: "FixtureCause", code: 42)
        AppLog("errors", diagnostics: errors).error("rich-error", error: NSError(domain: "FixtureError", code: 41, userInfo: [NSLocalizedDescriptionKey: "Bearer private-error", NSUnderlyingErrorKey: cause]))
        errors.bind(to: "mac-a")
        let errorEnvelope = try JSONSerialization.jsonObject(with: errors.batch(for: "mac-a")[0].data) as! [String: Any]
        let errorMetadata = (errorEnvelope["fields"] as! [String: Any])["error"] as! [String: Any]
        precondition(errorMetadata["code"] as? Int == 41 && (errorMetadata["cause"] as? [String: Any])?["code"] as? Int == 42)
        precondition((errorEnvelope["buildId"] as? String)?.count == 64, "Build identity belongs on every native event")
        precondition(!(errorMetadata["message"] as! String).contains("private-error"))

        let observed = NativeDiagnostics()
        var publications = 0
        let subscription = observed.objectWillChange.sink { publications += 1 }
        observed.record("visible-in-debug-panel")
        precondition(publications > 0)
        let recorded = publications
        observed.bind(to: "mac-a")
        observed.calibrate(hostID: "mac-a", serverTime: "2026-11-10T12:00:00.123Z", durationMs: 10)
        observed.acknowledge(observed.batch(for: "mac-a"))
        precondition(publications == recorded, "Outbox routing, calibration and delivery do not publish UI updates")
        withExtendedLifetime(subscription) {}

        let outbox = NativeDiagnostics()
        outbox.bind(to: "fixture")
        outbox.record("upload", fields: ["hostId": "fixture"])
        var uploads: [Data] = [], fail = true
        let base = URL(string: "http://fixture.invalid:7777")!
        let credentials = testCredentials()
        try credentials.pair(base, hostID: "fixture", token: "fixture-token")
        let api = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials, diagnostics: outbox) { request in
            precondition(request.url?.path == "/api/diagnostics/events")
            precondition(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            precondition(request.value(forHTTPHeaderField: "X-SlopZooka-Client-ID") != nil)
            precondition(request.value(forHTTPHeaderField: "X-SlopZooka-Host-ID") == "fixture")
            uploads.append(request.httpBody!)
            return try json(["ok": !fail], for: request, status: fail ? 503 : 200)
        }
        var health = fixtureHealth("fixture", endpoint: base)
        health.diagnosticsVersion = 1
        try api.accept(health, endpoint: base, authenticated: true)
        let pendingBeforeUpload = outbox.pendingCount
        await api.flushDiagnostics()
        precondition(outbox.pendingCount == pendingBeforeUpload, "Failure must retain the bounded outbox without recursively logging")
        fail = false
        await api.flushDiagnostics()
        precondition(outbox.pendingCount == 0 && uploads.count == 2 && uploads[0] == uploads[1], "Reconnect must retry original identities and acknowledge only success")
        let requestsLog = NativeDiagnostics()
        var status = 200
        var cancelled = false
        var controlRequests: [URLRequest] = []
        let control = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials(), diagnostics: requestsLog) { request in
            controlRequests.append(request)
            if cancelled { throw URLError(.cancelled) }
            return try json(status == 200 ? ["ok": true] : ["error": "private-server-body"], for: request, status: status)
        }
        let other = URL(string: "http://other.invalid:7777")!
        try control.accept(fixtureHealth("mac-a", endpoint: base), endpoint: base, authenticated: true)
        try control.accept(fixtureHealth("mac-b", endpoint: other), endpoint: other, authenticated: true)
        try await control.endSession(hostID: "mac-a", id: "session")
        let requestEvents = try JSONSerialization.jsonObject(with: requestsLog.body(for: requestsLog.batch(for: "mac-a"))) as! [String: Any]
        let completed = (requestEvents["events"] as! [[String: Any]]).first { $0["event"] as? String == "http.completed" }!
        let context = completed["fields"] as! [String: String]
        precondition(context["hostId"] == "mac-a" && context["actionId"] == controlRequests.last!.value(forHTTPHeaderField: "X-SlopZooka-Action-ID"), "Request instrumentation must use the injected runtime and requested host, not the active Mac")
        requestsLog.acknowledge(requestsLog.batch(for: "mac-a"))
        status = 503
        do { try await control.endSession(hostID: "mac-a", id: "session"); preconditionFailure("Expected HTTP failure") }
        catch { }
        let failureBody = requestsLog.body(for: requestsLog.batch(for: "mac-a"))
        let failureEvents = (try JSONSerialization.jsonObject(with: failureBody) as! [String: Any])["events"] as! [[String: Any]]
        precondition(failureEvents.filter { $0["level"] as? String == "warn" }.count == 1, "An HTTP failure should have one outcome event")
        precondition(!String(decoding: failureBody, as: UTF8.self).contains("private-server-body"))
        requestsLog.acknowledge(requestsLog.batch(for: "mac-a"))
        cancelled = true
        do { try await control.endSession(hostID: "mac-a", id: "session"); preconditionFailure("Expected cancellation") }
        catch { }
        let cancelledBody = requestsLog.body(for: requestsLog.batch(for: "mac-a"))
        let cancelledEvents = (try JSONSerialization.jsonObject(with: cancelledBody) as! [String: Any])["events"] as! [[String: Any]]
        precondition(cancelledEvents.contains { $0["event"] as? String == "http.cancelled" })
        precondition(!cancelledEvents.contains { ["warn", "error"].contains($0["level"] as? String ?? "") }, "Ordinary cancellation is control flow, not an application error")

        let menu = NativeDiagnostics()
        menu.enableMacLogging()
        let root = menu.logDirectory!
        precondition(root.path.hasPrefix(CommandLine.arguments[2]), "Disk checks must stay inside the test home")
        let directory = root.appendingPathComponent("mac-menu")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<4 {
            try Data(repeating: 32, count: 4 * 1024 * 1024).write(to: directory.appendingPathComponent("\(index)-aaaaaaaa.jsonl"))
        }
        let current = directory.appendingPathComponent("current.jsonl")
        var crash = first[0].data
        crash.append(Data("\n{\"partial\":".utf8))
        try crash.write(to: current)
        let expired = directory.appendingPathComponent("1-bbbbbbbb.jsonl")
        try Data("{}\n".utf8).write(to: expired)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: expired.path)
        menu.record("menu.fixture")
        for _ in 0..<100 where menu.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(menu.pendingCount == 0)
        let retainedCrash = try Data(contentsOf: current)
        precondition(retainedCrash == crash, "A new writer never repairs or appends to a previous process's crash tail")
        precondition(!FileManager.default.fileExists(atPath: expired.path), "Expired segments are pruned when opening a segment")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let small = try files.filter {
            guard $0.lastPathComponent != current.lastPathComponent else { return false }
            return try ($0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 8192
        }
        let entries = try small.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        let written = try entries.compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        precondition(written.contains { $0["source"] as? String == "mac-menu" && $0["event"] as? String == "menu.fixture" })
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(total <= 16 * 1024 * 1024, "The native writer must reserve segment capacity within its role budget")

        let ringDirectory = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("native-ring")
        let ring = NativeLogFile(directory: ringDirectory)
        let segment = Data(repeating: 10, count: 4 * 1024 * 1024)
        for _ in 0..<6 {
            let ok = await ring.append(segment)
            precondition(ok)
            let segments = try FileManager.default.contentsOfDirectory(at: ringDirectory, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = try segments.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            precondition(segments.count <= 4 && bytes <= 16 * 1024 * 1024, "Rolling reserves a complete new segment and prunes only closed files")
        }
        let blocked = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("blocked-native-writer")
        try Data("blocked".utf8).write(to: blocked)
        let recovering = NativeLogFile(directory: blocked)
        let failed = await recovering.append(Data("{}\n".utf8))
        precondition(!failed)
        try FileManager.default.removeItem(at: blocked)
        let recovered = await recovering.append(Data("{}\n".utf8))
        precondition(recovered, "Disk failures remain retryable without retaining a broken append target")
        CompanionTestPreferences.clean()
        print("PASS: native diagnostics preserve the wire contract, redact secrets, bound offline history, isolate hosts, and retry authenticated batches")
    }
}
