import AppKit
import Combine
import ServiceManagement

@MainActor
final class CompanionModel: ObservableObject {
    @Published var state = "Starting"
    @Published var detail = "Getting your Mac ready"
    @Published var code = ""
    @Published var sessions = 0
    @Published var viewers = 0
    @Published var frontends = 0
    @Published var ready = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNotice: String?
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var retry: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var failures = 0
    private var startedAt = Date()
    private var quitting = false
    var onStopped: (() -> Void)?
    private let port = ProcessInfo.processInfo.environment["SLOPZOOKA_PORT"] ?? "7777"
    var dashboard: URL { URL(string: "http://localhost:\(port)/")! }
    var logDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SLOPZOOKA_LOG_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SlopZooka")
    }

    func start() {
        guard child == nil, !quitting else { return }
        retry?.cancel()
        state = "Starting"
        detail = "Getting your Mac ready"
        ready = false
        code = ""
        buffer.removeAll()
        guard let resources = Bundle.main.resourceURL else {
            fail("App resources are missing. Rebuild the app.")
            return
        }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("runtime/node")
        process.arguments = [resources.appendingPathComponent("host/src/server.mjs").path]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // Finder has a minimal PATH. The host's login shells still load the user's agent configuration.
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        ]
        environment["PATH"] =
            ([resources.appendingPathComponent("runtime").path] + extra + [
                environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            ]).joined(separator: ":")
        environment["SLOPZOOKA_DESKTOP"] = "1"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        input = stdin
        output = stdout
        process.standardInput = stdin
        process.standardOutput = stdout
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let log = logDirectory.appendingPathComponent("desktop-stderr.log")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            stderr = handle
            process.standardError = handle
            stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                Task { @MainActor in
                    guard let self, self.child === process else { return }
                    self.receive(data)
                }
            }
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in self?.ended(process) }
            }
            child = process
            startedAt = Date()
            try process.run()
            // The child owns its read end; keeping another read end is unnecessary.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            startupDeadline = Task { [weak self, weak process] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.child === process, !self.ready else { return }
                self.detail = "The companion did not start. Check logs, then retry."
                process?.terminate()
            }
        } catch {
            output?.fileHandleForReading.readabilityHandler = nil
            child = nil
            input = nil
            output = nil
            try? stderr?.close()
            stderr = nil
            fail("Could not start the bundled companion. Rebuild the app or check logs.")
        }
    }

    private struct Status: Decodable {
        let code: String
        let sessions: Int
        let viewers: Int
        let frontends: Int
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            let prefix = Data("SLZ_DESKTOP ".utf8)
            guard line.starts(with: prefix),
                let status = try? JSONDecoder().decode(Status.self, from: line.dropFirst(prefix.count))
            else { continue }
            startupDeadline?.cancel()
            ready = true
            state = "Running"
            detail =
                status.viewers > 0
                ? "\(status.viewers) connected terminal viewer\(status.viewers == 1 ? "" : "s")"
                : "Ready for Vision Pro"
            code = status.code
            sessions = status.sessions
            viewers = status.viewers
            frontends = status.frontends
        }
        if buffer.count > 64 * 1024 { buffer.removeAll() }
    }

    private func ended(_ process: Process) {
        guard child === process else { return }
        startupDeadline?.cancel()
        let wasReady = ready
        child = nil
        output?.fileHandleForReading.readabilityHandler = nil
        input = nil
        output = nil
        try? stderr?.close()
        stderr = nil
        ready = false
        code = ""
        sessions = 0
        viewers = 0
        frontends = 0
        if quitting {
            onStopped?()
            return
        }
        if Date().timeIntervalSince(startedAt) > 60 { failures = 0 }
        failures += 1
        // Never loop on startup errors (especially a companion already listening on this port).
        guard wasReady, failures <= 3 else {
            fail(
                "Could not keep the companion running. If it is open in Terminal, stop it there first. See logs for details."
            )
            return
        }
        state = "Reconnecting"
        detail = "The companion stopped. Restarting; previous terminal sessions have ended."
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
    private func fail(_ message: String) {
        state = "Needs attention"
        detail = message
        ready = false
    }
    func retryStart() {
        failures = 0
        start()
    }
    func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNotice =
                SMAppService.mainApp.status == .requiresApproval
                ? "Allow SlopZooka in System Settings → Login Items." : nil
        } catch { loginNotice = "Could not update login settings. Move the app to Applications and try again." }
    }
    func stop() {
        quitting = true
        retry?.cancel()
        startupDeadline?.cancel()
        guard let child else {
            onStopped?()
            return
        }
        state = "Stopping"
        ready = false
        try? input?.fileHandleForWriting.close()
        if child.isRunning { child.terminate() }
    }
}
