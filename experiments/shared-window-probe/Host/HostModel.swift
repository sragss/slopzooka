import AppKit
import ScreenCaptureKit
import Security
import CryptoKit
import ImageIO

@MainActor final class HostModel: ObservableObject {
    @Published var message = "Stopped. No capture or server starts until you arm the experiment."
    @Published var windows: [SCWindow] = []
    @Published var targets: [Surface] = []
    @Published var statusText = "unknown"
    @Published var connection = ""
    @Published var seconds = 1800.0
    @Published var lan = false
    @Published var running = false
    let runDirectory: URL
    private var gate = Gate()
    private let desktop = DesktopMonitor()
    private let server = ProbeServer()
    private let processes = OwnedProcesses()
    private var heartbeat: Timer?
    private var token = ""
    private var fingerprint = ""
    private var port: UInt16 = 0
    private var busy = false
    private var eventFile: FileHandle?
    @MainActor final class Surface: Identifiable {
        let id = UUID().uuidString
        var label: String
        let kind: String
        let udid: String?
        var window: SCWindow?
        let ax = AXTarget()
        var capture: WindowCapture?
        var polling: Task<Void, Never>?
        var mjpeg: MJPEGSource?
        var state = "starting"
        var lastFrame = 0.0
        var frames = 0
        var bytes = 0
        var width = 0
        var height = 0
        var error = ""
        var lastProbe: [String: Any] = [:]
        init(window: SCWindow) {
            self.window = window; udid = nil; kind = "mac-window"
            label = "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Untitled")"
        }
        init(udid: String) { window = nil; self.udid = udid; kind = "simulator-snapshots"; label = "Simulator \(udid) (PNG diagnostic stream)" }
    }
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--run-dir"), args.count > i + 1 { runDirectory = URL(fileURLWithPath: args[i+1]) }
        else { runDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SlopZookaProbe") }
    }
    func start() throws {
        guard !running else { return }
        let p12 = try Data(contentsOf: runDirectory.appendingPathComponent("identity.p12"))
        let cert = try Data(contentsOf: runDirectory.appendingPathComponent("certificate.der"))
        var items: CFArray?
        let code = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: "probe-local-only",
                                                kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard code == errSecSuccess, let item = (items as? [[String: Any]])?.first,
              let rawIdentity = item[kSecImportItemIdentity as String] else {
            throw ProbeFailure("identity_unavailable", "Run the preparation script first (PKCS12 \(code))")
        }
        let identity = rawIdentity as! SecIdentity
        token = (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        fingerprint = SHA256.hash(data: cert).map { String(format: "%02x", $0) }.joined()
        try gate.arm(seconds: seconds, now: uptime())
        let eventURL = runDirectory.appendingPathComponent("events-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: eventURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        eventFile = try FileHandle(forWritingTo: eventURL)
        server.handle = { [weak self] request, reply in
            Task { @MainActor in
                guard let self else { reply(.json(["error": "host_stopped"], status: 503)); return }
                reply(await self.handle(request))
            }
        }
        server.onStream = { [weak self] id in Task { @MainActor in self?.targets.first(where: { $0.id == id })?.capture?.requestKeyframe() } }
        server.onError = { [weak self] error in Task { @MainActor in self?.message = error; self?.stop() } }
        server.onReady = { [weak self] port in Task { @MainActor in
            guard let self, self.running else { return }
            self.port = port
            let config: [String: Any] = ["host": "127.0.0.1", "port": port, "pid": ProcessInfo.processInfo.processIdentifier, "token": self.token, "fingerprint": self.fingerprint]
            let url = self.runDirectory.appendingPathComponent("connection.json")
            try? jsonData(config).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.connection = String(data: jsonData(config), encoding: .utf8) ?? ""
            self.message = "Listening on \(self.lan ? "LAN" : "loopback") port \(port). Select windows during the test slot."
        } }
        try server.start(identity: identity, token: token, lan: lan)
        running = true
        desktop.changed = { [weak self] state, source in self?.desktopChanged(state, source) }
        desktop.start()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        event("armed", ["seconds": seconds, "lan": lan])
    }
    private func desktopChanged(_ state: String, _ source: String) {
        let changed = gate.update(state, source: source, now: uptime())
        statusText = "\(state) — \(source)"
        guard changed else { return }
        event("desktop", ["state": state, "source": source, "generation": gate.generation])
        // A stream socket never straddles a desktop generation. Device streams reconnect,
        // but remain independently callable; desktop streams require explicit resume.
        server.disconnectStreams()
        for target in targets where target.kind == "mac-window" {
            target.state = state == "unlocked" ? "resume_required" : "desktop_\(state)"
            target.ax.clear()
            if let capture = target.capture { target.capture = nil; Task { await capture.stop() } }
        }
        objectWillChange.send()
    }
    func confirmLocal() { desktop.confirmLocal() }
    private func tick() {
        guard running else { return }
        if (try? gate.checkRun(now: uptime())) == nil { stop(); return }
        for target in targets {
            var header = MediaHeader(kind: "status", generation: gate.generation)
            header.reason = target.state
            server.broadcast(MediaPacket(header: header, payload: jsonData(snapshot())), target: target.id)
        }
        objectWillChange.send()
    }
    func stop() {
        guard running else { return }
        gate.stop(); running = false; heartbeat?.invalidate(); heartbeat = nil
        desktop.stop(); processes.cancelAll(); server.stop()
        for target in targets {
            target.polling?.cancel(); target.polling = nil
            target.mjpeg?.stop(); target.mjpeg = nil
            if let capture = target.capture { target.capture = nil; Task { await capture.stop() } }
            target.ax.clear(); target.state = "stopped"
        }
        event("stopped", [:]); try? eventFile?.close(); eventFile = nil
        try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("connection.json"))
        connection = ""; message = "Stopped. Owned streams and screenshot jobs cancelled."
    }
    func refresh() async throws {
        try gate.checkDesktop(expected: gate.generation, now: uptime())
        guard CGPreflightScreenCaptureAccess() else { throw ProbeFailure("capture_permission_denied", "Grant Screen Recording to ProbeHost, then retry/relaunch") }
        let generation = gate.generation
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        try gate.checkDesktop(expected: generation, now: uptime())
        windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 }
    }
    func share(_ windowID: UInt32) async throws -> String {
        if let existing = targets.first(where: { $0.window?.windowID == windowID }) { return existing.id }
        guard targets.count < 4 else { throw ProbeFailure("target_limit", "This experiment allows four simultaneous targets") }
        if !windows.contains(where: { $0.windowID == windowID }) { try await refresh() }
        guard let window = windows.first(where: { $0.windowID == windowID }) else { throw ProbeFailure("window_gone", "Refresh the window inventory") }
        let target = Surface(window: window); targets.append(target)
        do { try await resume(target); return target.id }
        catch { target.state = "failed"; target.error = error.localizedDescription; throw error }
    }
    private func resume(_ target: Surface) async throws {
        try gate.checkDesktop(expected: gate.generation, now: uptime())
        guard let previousWindow = target.window else { return }
        guard target.capture == nil else { return }
        try await refresh()
        guard let window = windows.first(where: { $0.windowID == previousWindow.windowID && $0.owningApplication?.processID == previousWindow.owningApplication?.processID }) else {
            throw ProbeFailure("window_gone", "Selected window no longer exists; explicitly select a replacement")
        }
        target.window = window
        let generation = gate.generation
        let capture = WindowCapture()
        capture.packet = { [weak self, weak target, weak capture] packet in
            Task { @MainActor in
                guard let self, let target, let capture, self.targets.contains(where: { $0 === target }),
                      (try? self.gate.checkDesktop(expected: generation, now: uptime())) != nil,
                      target.capture === capture else { return }
                target.frames += 1; target.bytes += packet.payload.count
                target.width = packet.header.width; target.height = packet.header.height
                self.server.broadcast(packet, target: target.id)
            }
        }
        capture.state = { [weak self, weak target, weak capture] state in Task { @MainActor in
            guard let self, let target, let capture, target.capture === capture else { return }
            if state == "complete" { target.lastFrame = uptime() }
            target.state = state
            if ["blank", "suspended", "stopped"].contains(state) {
                self.server.broadcast(MediaPacket(header: MediaHeader(kind: "paused", generation: generation, reason: state)), target: target.id)
            }
        } }
        capture.error = { [weak self, weak target, weak capture] error in Task { @MainActor in
            guard let self, let target, let capture, target.capture === capture else { return }
            target.error = error; target.state = "failed"
            target.capture = nil
            Task { await capture.stop() }
            self.server.broadcast(MediaPacket(header: MediaHeader(kind: "paused", generation: generation, reason: error)), target: target.id)
        } }
        target.capture = capture; target.state = "starting"
        do {
            try await capture.start(window: window, generation: generation)
            try gate.checkDesktop(expected: generation, now: uptime())
            if let pid = window.owningApplication?.processID {
                do { try target.ax.bind(pid: pid, bounds: window.frame, title: window.title ?? "") }
                catch { target.error = "Stream works independently; AX: \(error.localizedDescription)" }
            }
            event("share", ["target": target.id, "windowID": window.windowID])
        } catch { target.capture = nil; await capture.stop(); throw error }
    }
    func snapshot() -> [String: Any] {
        ["armed": running, "generation": gate.generation, "remainingSeconds": gate.expires.isFinite ? max(0, gate.expires - uptime()) as Any : NSNull(),
         "untilStopped": !gate.expires.isFinite,
         "network": server.stats(),
         "desktop": ["state": gate.desktop, "source": gate.source, "observedUptime": gate.lastSignal],
         "permissions": ["screenCapture": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()],
         "targets": targets.map { t in
            ["id": t.id, "label": t.label, "kind": t.kind, "state": t.state, "error": t.error,
             "windowID": t.window?.windowID as Any? ?? NSNull(), "udid": t.udid as Any? ?? NSNull(),
             "width": t.width, "height": t.height, "frames": t.frames, "bytes": t.bytes,
             "lastCapturedUptime": t.lastFrame, "lastProbe": t.lastProbe] as [String: Any]
         }, "capabilities": ["desktop": gate.desktop == "unlocked" && running ? "permission_and_target_checks_required" : "blocked",
             "simulatorScreenshot": "probe_required", "simulatorInteractive": "external_wda_adapter",
             "simulatorUITest": "external_bounded_runner"]]
    }
    private func simulatorShot(_ target: Surface) async throws -> Data {
        try gate.checkRun(now: uptime())
        guard let udid = target.udid else { throw ProbeFailure("not_simulator", "Not a simulator target") }
        let before = gate.desktop, start = uptime()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slz-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("screen.png")
        _ = try await processes.run("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", "--type=png", output.path], timeout: min(10, gate.expires - uptime()))
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 16 * 1024 * 1024 else { throw ProbeFailure("output_limit", "Screenshot exceeds limit") }
        let data = try Data(contentsOf: output)
        try gate.checkRun(now: uptime())
        guard data.starts(with: [137,80,78,71,13,10,26,10]) else { throw ProbeFailure("invalid_image", "Simulator did not return PNG") }
        target.lastProbe = ["provider": "simctl", "startedDesktop": before, "finishedDesktop": gate.desktop,
                            "duration": uptime() - start, "imageFreshness": "requires_fixture_nonce_check"]
        target.lastFrame = uptime()
        event("device_screenshot", ["target": target.id, "desktopBefore": before, "desktopAfter": gate.desktop])
        return data
    }
    private func attachSimulator(_ udid: String) async throws -> Surface {
        guard UUID(uuidString: udid) != nil else { throw ProbeFailure("explicit_udid_required", "Use a specific simulator UUID, never booted") }
        if let target = targets.first(where: { $0.udid == udid }) { return target }
        guard targets.count < 4 else { throw ProbeFailure("target_limit", "Remove a target first") }
        let target = Surface(udid: udid)
        _ = try await simulatorShot(target) // No boot/install/launch side effects.
        targets.append(target); target.state = "snapshot_ready"
        return target
    }
    private func startDeviceStream(_ target: Surface) {
        target.mjpeg?.stop(); target.mjpeg = nil
        target.label = "Simulator \(target.udid ?? "") (PNG diagnostic stream)"
        target.polling?.cancel()
        target.polling = Task { @MainActor [weak self, weak target] in
            guard let self, let target else { return }
            while !Task.isCancelled, self.running, self.targets.contains(where: { $0 === target }) {
                do {
                    let data = try await self.simulatorShot(target)
                    try Task.checkCancellation()
                    let rep = NSBitmapImageRep(data: data)
                    target.width = rep?.pixelsWide ?? 0; target.height = rep?.pixelsHigh ?? 0
                    target.frames += 1; target.bytes += data.count; target.state = "diagnostic_png_1fps"
                    self.server.broadcast(MediaPacket(header: MediaHeader(kind: "png", generation: self.gate.generation,
                        sequence: target.frames, timestamp: uptime(), width: target.width, height: target.height), payload: data), target: target.id)
                } catch {
                    if Task.isCancelled { break }
                    target.state = "failed"; target.error = error.localizedDescription
                    self.server.broadcast(MediaPacket(header: MediaHeader(kind: "paused", generation: self.gate.generation, reason: target.error)), target: target.id)
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private func startMJPEG(_ target: Surface, url: URL) throws {
        guard target.udid != nil else { throw ProbeFailure("not_simulator", "MJPEG requires an explicitly bound simulator target") }
        target.polling?.cancel(); target.polling = nil
        target.mjpeg?.stop()
        let source = MJPEGSource(); target.mjpeg = source; target.state = "mjpeg_starting"
        target.label = "Simulator \(target.udid!) (continuous JPEG)"
        source.image = { [weak self, weak target, weak source] bytes in
            guard let self, let target, let source, target.mjpeg === source,
                  self.targets.contains(where: { $0 === target }), (try? self.gate.checkRun(now: uptime())) != nil else { return }
            target.lastFrame = uptime(); target.frames += 1; target.bytes += bytes.count; target.state = "device_mjpeg"
            if let image = CGImageSourceCreateWithData(bytes as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                target.width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                target.height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            self.server.broadcast(MediaPacket(header: MediaHeader(kind: "jpeg", generation: self.gate.generation,
                sequence: target.frames, timestamp: uptime()), payload: bytes), target: target.id)
        }
        source.failed = { [weak self, weak target] error in
            guard let self, let target else { return }; target.state = "failed"; target.error = error
            self.server.broadcast(MediaPacket(header: MediaHeader(kind: "paused", generation: self.gate.generation, reason: error)), target: target.id)
        }
        try source.start(url)
        event("mjpeg_started", ["target": target.id, "udid": target.udid!])
    }
    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            if request.method == "GET", request.path == "/status" { return .json(snapshot()) }
            if request.method == "GET", request.path.hasPrefix("/stream/") {
                try gate.checkRun(now: uptime())
                let id = String(request.path.dropFirst(8))
                guard targets.contains(where: { $0.id == id }) else { return .json(["error": "target_gone"], status: 404) }
                event("stream_attached", ["target": id]); return .json(["accepted": true])
            }
            if request.method == "GET", request.path == "/windows" {
                try await refresh()
                return .json(["generation": gate.generation, "windows": windows.map { ["windowID": $0.windowID,
                    "app": $0.owningApplication?.applicationName ?? "", "title": $0.title ?? "", "bounds": rectJSON($0.frame)] as [String: Any] }])
            }
            if request.method == "GET", request.path.hasPrefix("/snapshot/") {
                let id = String(request.path.dropFirst(10))
                guard let target = targets.first(where: { $0.id == id }) else { throw ProbeFailure("target_gone", "Unknown target") }
                let image: Data
                if let window = target.window {
                    let generation = gate.generation; try gate.checkDesktop(expected: generation, now: uptime())
                    image = try await WindowCapture.screenshot(window: window)
                    try gate.checkDesktop(expected: generation, now: uptime())
                } else { image = try await simulatorShot(target) }
                guard targets.contains(where: { $0 === target }) else { throw ProbeFailure("target_gone", "Target was removed during screenshot") }
                return HTTPResponse(type: "image/png", body: image)
            }
            guard request.method == "POST", request.path == "/command" else { return .json(["error": "not_found"], status: 404) }
            let command = try JSONDecoder().decode(Command.self, from: request.body)
            if command.action == "stop" { stop(); return .json(["stopped": true]) }
            try gate.checkRun(now: uptime())
            guard !busy else { throw ProbeFailure("busy", "Another command is in flight; do not queue input") }
            busy = true; defer { busy = false }
            let result: [String: Any]
            if command.action == "share", let id = command.windowID {
                try gate.checkDesktop(expected: command.generation, now: uptime())
                result = ["target": try await share(id)]
            } else if command.action == "attachSimulator", let udid = command.udid {
                result = ["target": try await attachSimulator(udid).id]
            } else {
                guard let id = command.target, let target = targets.first(where: { $0.id == id }) else { throw ProbeFailure("target_required", "Select an existing target") }
                switch command.action {
                case "remove":
                    target.polling?.cancel()
                    target.mjpeg?.stop(); target.mjpeg = nil
                    targets.removeAll { $0 === target }
                    if let capture = target.capture { target.capture = nil; await capture.stop() }
                    server.broadcast(MediaPacket(header: MediaHeader(kind: "paused", generation: gate.generation, reason: "removed")), target: id)
                    result = ["removed": id]
                case "deviceStream": startDeviceStream(target); result = ["starting": true]
                case "deviceMJPEG":
                    guard let text = command.url, let url = URL(string: text) else { throw ProbeFailure("url_required", "Supply owned WDA MJPEG URL") }
                    try startMJPEG(target, url: url); result = ["starting": true]
                case "resume":
                    try gate.checkDesktop(expected: command.generation, now: uptime())
                    try await resume(target); result = ["resumed": id]
                case "observe":
                    try gate.checkDesktop(expected: command.generation, now: uptime())
                    result = try target.ax.inspect()
                case "resize", "press", "setValue":
                    try gate.checkDesktop(expected: command.generation, now: uptime())
                    result = try target.ax.perform(command)
                    event("desktop_action", ["action": command.action, "target": id, "generation": gate.generation])
                default: throw ProbeFailure("unsupported_command", "Unknown command")
                }
            }
            var body = result; body["generation"] = gate.generation
            return .json(body)
        } catch {
            let failure = error as? ProbeFailure
            event("rejected_or_failed", ["code": failure?.code ?? "error", "message": error.localizedDescription])
            return .json(["error": failure?.code ?? "error", "message": error.localizedDescription, "status": snapshot()], status: 409)
        }
    }
    private func event(_ name: String, _ fields: [String: Any]) {
        var entry = fields; entry["event"] = name; entry["uptime"] = uptime(); entry["at"] = ISO8601DateFormatter().string(from: Date())
        var data = jsonData(entry); data.append(10); try? eventFile?.write(contentsOf: data)
    }
}
