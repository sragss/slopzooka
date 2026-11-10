import AppKit
import Combine
import Darwin
import ServiceManagement

@MainActor
final class CompanionModel: ObservableObject {
    private let log = AppLog("supervision")
    init() { NativeDiagnostics.shared.enableMacLogging() }
    @Published var state = "Starting"
    @Published var detail = "Getting your Mac ready"
    @Published var code = ""
    @Published var pairingDisplayUntil: TimeInterval = 0
    @Published var sessions = 0
    @Published var viewers = 0
    @Published var frontends = 0
    @Published var ready = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNotice: String?
    @Published var openingDashboard = false
    @Published var dashboardError: String?
    @Published var serviceBusy = false
    @Published var serviceError: String?
    private var serviceRequest: String?
    private var serviceDeadline: Task<Void, Never>?
    private var restartingCompanion = false
    private var dashboardRequest: String?
    private var dashboardDeadline: Task<Void, Never>?
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var retry: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var stopDeadline: Task<Void, Never>?
    private var lastStatus: Status?
    private var startupFailure: String?
    private var failures = 0
    private var startedAt = Date()
    private var quitting = false
    var onStopped: (() -> Void)?
    var logDirectory: URL {
        NativeDiagnostics.shared.logDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".slopzooka/logs")
    }

    func showLogs() {
        NSWorkspace.shared.open(logDirectory)
        if let path = lastStatus?.sessionLogPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func start() {
        guard child == nil, !quitting else { return }
        log.info("companion.start.requested")
        retry?.cancel()
        state = "Starting"
        detail = "Getting your Mac ready"
        ready = false
        code = ""
        buffer.removeAll()
        lastStatus = nil
        startupFailure = nil
        dashboardError = nil
        serviceError = nil
        finishOpeningDashboard()
        guard let resources = Bundle.main.resourceURL else {
            fail("App resources are missing. Rebuild the app.")
            return
        }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("runtime/node")
        process.arguments = [
            "--require", resources.appendingPathComponent("session-runtime/bootstrap.cjs").path,
            resources.appendingPathComponent("host/src/server.mjs").path,
        ]
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
        environment["SLOPZOOKA_HOME"] = logDirectory.deletingLastPathComponent().path
        environment["SLOPZOOKA_DIAGNOSTICS_DIR"] = logDirectory.path
        environment["SLOPZOOKA_DIAGNOSTICS_ROLE"] = "mac-companion"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        input = stdin
        output = stdout
        process.standardInput = stdin
        process.standardOutput = stdout
        // Fatal startup failures use the bounded preload fallback. stdout remains
        // the private credential-bearing control pipe and is never captured.
        process.standardError = FileHandle.nullDevice
        do {
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
                self.startupFailure = "The companion did not respond during startup. Check logs, then retry."
                self.detail = "Stopping an unresponsive companion…"
                if let process { self.terminateOwnedProcess(process) }
            }
        } catch {
            log.error("companion.launch.failed", error: error)
            output?.fileHandleForReading.readabilityHandler = nil
            child = nil
            input = nil
            output = nil
            fail("Could not start the bundled companion. Rebuild the app or check logs.")
        }
    }

    private struct Status: Decodable, Equatable {
        let code: String
        let pairingDisplayUntil: Double?
        let sessions: Int
        let viewers: Int
        let frontends: Int
        let sessionServiceAvailable: Bool?
        let sessionLogPath: String?
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            let servicePrefix = Data("SLZ_SERVICE ".utf8)
            if line.starts(with: servicePrefix) {
                if let reply = try? JSONDecoder().decode(ServiceReply.self, from: line.dropFirst(servicePrefix.count)),
                    reply.requestId == serviceRequest {
                    finishServiceCommand()
                    serviceError = reply.error
                }
                continue
            }
            let dashboardPrefix = Data("SLZ_DASHBOARD ".utf8)
            if line.starts(with: dashboardPrefix) {
                if let reply = try? JSONDecoder().decode(DashboardReply.self, from: line.dropFirst(dashboardPrefix.count)),
                    reply.requestId == dashboardRequest, ready, !quitting,
                    let url = URL(string: reply.url), ["http", "https"].contains(url.scheme ?? "") {
                    finishOpeningDashboard()
                    if !NSWorkspace.shared.open(url) { dashboardError = "Could not open your browser. Try again." }
                }
                continue
            }
            let prefix = Data("SLZ_DESKTOP ".utf8)
            guard line.starts(with: prefix),
                let status = try? JSONDecoder().decode(Status.self, from: line.dropFirst(prefix.count))
            else { continue }
            guard !quitting, startupFailure == nil, status != lastStatus else { continue }
            lastStatus = status
            startupDeadline?.cancel()
            ready = true
            state = "Running"
            detail = status.sessionServiceAvailable == false
                ? "Session service stopped or unavailable"
                : status.viewers > 0
                ? "\(status.viewers) connected terminal viewer\(status.viewers == 1 ? "" : "s")"
                : "Ready for Vision Pro"
            code = status.code
            pairingDisplayUntil = (status.pairingDisplayUntil ?? 0) / 1000
            sessions = status.sessions
            viewers = status.viewers
            frontends = status.frontends
        }
        if buffer.count > 64 * 1024 { buffer.removeAll() }
    }

    private func ended(_ process: Process) {
        guard child === process else { return }
        log.info("companion.exited", ["status": String(process.terminationStatus), "reason": String(process.terminationReason.rawValue)])
        startupDeadline?.cancel()
        stopDeadline?.cancel()
        finishOpeningDashboard()
        finishServiceCommand()
        let wasReady = ready
        child = nil
        output?.fileHandleForReading.readabilityHandler = nil
        input = nil
        output = nil
        ready = false
        code = ""
        sessions = 0
        pairingDisplayUntil = 0
        viewers = 0
        frontends = 0
        if quitting {
            onStopped?()
            return
        }
        if restartingCompanion {
            restartingCompanion = false
            start()
            return
        }
        if let startupFailure {
            fail(startupFailure)
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
        detail = "The companion stopped. Reconnecting to your terminal sessions."
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
    private func fail(_ message: String) {
        log.warn("companion.unavailable", ["reason": message])
        state = "Needs attention"
        detail = message
        ready = false
    }
    func retryStart() {
        failures = 0
        start()
    }
    private struct DashboardReply: Decodable {
        let requestId: String
        let url: String
    }
    func openDashboard() {
        guard ready, !openingDashboard, let input else { return }
        dashboardError = nil
        let requestId = UUID().uuidString
        dashboardRequest = requestId
        openingDashboard = true
        do {
            var data = try JSONSerialization.data(withJSONObject: ["type": "open-dashboard", "requestId": requestId])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            dashboardDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.dashboardRequest == requestId else { return }
                self.finishOpeningDashboard()
                self.dashboardError = "Could not open the dashboard. Try again."
            }
        } catch {
            finishOpeningDashboard()
            dashboardError = "Could not open the dashboard. Try again."
        }
    }
    private func finishOpeningDashboard() {
        dashboardDeadline?.cancel()
        dashboardDeadline = nil
        dashboardRequest = nil
        openingDashboard = false
    }
    func restartCompanion() {
        log.info("companion.restart.requested")
        guard let child, !quitting else { return }
        restartingCompanion = true
        ready = false
        terminateOwnedProcess(child)
    }
    private struct ServiceReply: Decodable {
        let requestId: String
        let error: String?
    }
    func manageSessionService(restart: Bool) {
        guard ready, !serviceBusy, let input else { return }
        let alert = NSAlert()
        alert.messageText = restart ? "Restart session service?" : "End all sessions and stop service?"
        alert.informativeText = "This ends all running terminals, agents, and their attached dev servers. Restarting the companion alone keeps them running."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: restart ? "End Sessions and Restart" : "End Sessions and Stop")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        serviceError = nil
        let requestId = UUID().uuidString
        serviceRequest = requestId
        serviceBusy = true
        do {
            var data = try JSONSerialization.data(withJSONObject: ["type": restart ? "restart-session-service" : "stop-session-service", "requestId": requestId])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            serviceDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.serviceRequest == requestId else { return }
                self.finishServiceCommand()
                self.serviceError = "The session service did not respond. Check logs before retrying."
            }
        } catch {
            finishServiceCommand()
            serviceError = "Could not reach the companion. Restart the companion and try again."
        }
    }
    private func finishServiceCommand() {
        serviceDeadline?.cancel()
        serviceDeadline = nil
        serviceRequest = nil
        serviceBusy = false
    }
    func setLogin(_ enabled: Bool) {
        log.info("login.changed", ["enabled": String(enabled)])
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNotice =
                SMAppService.mainApp.status == .requiresApproval
                ? "Allow SlopZooka in System Settings → Login Items." : nil
        } catch { loginNotice = "Could not update login settings. Move the app to Applications and try again." }
    }
    func stop() {
        log.info("companion.stop.requested")
        quitting = true
        restartingCompanion = false
        finishServiceCommand()
        finishOpeningDashboard()
        retry?.cancel()
        startupDeadline?.cancel()
        guard let child else {
            onStopped?()
            return
        }
        state = "Stopping"
        ready = false
        terminateOwnedProcess(child)
    }

    private func terminateOwnedProcess(_ child: Process) {
        stopDeadline?.cancel()
        try? input?.fileHandleForWriting.close()
        if child.isRunning { child.terminate() }
        // A wedged event loop cannot handle SIGTERM; never leave Quit waiting indefinitely.
        stopDeadline = Task { [weak self, weak child] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let child, self.child === child, child.isRunning else { return }
            Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }
}
