import AppKit
import Foundation
import Network
@preconcurrency import ScreenCaptureKit

/// Screen permission belongs to this signed component. It never injects input,
/// launches source apps, or owns terminal/workspace lifetime.
@main
struct WindowHost {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = WindowSourceHost()
        Task { await host.start() }
        DispatchQueue.global().async {
            var buffer = Data()
            while true {
                let chunk = FileHandle.standardInput.readData(ofLength: 4096)
                if chunk.isEmpty { exit(0) } // Parent lifeline, including idle captures.
                buffer.append(chunk)
                guard buffer.count <= 16_384 else { exit(2) }
                while let newline = buffer.firstIndex(of: 10) {
                    let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let command = try? JSONDecoder().decode(WindowCommand.self, from: data) else { exit(2) }
                    Task { await host.handle(command) }
                }
            }
        }
        NSApplication.shared.run()
    }
}

nonisolated struct WindowCommand: Decodable, Sendable { let id: UUID; let method: String; var sourceID: String? }
nonisolated struct CapturedWindow: Codable, Sendable {
    let id: String
    let title: String
    let application: String
    let contentWidth: Double
    let contentHeight: Double
}

@MainActor
private final class WindowSourceHost {
    private let epoch = UUID().uuidString.lowercased()
    private var sources: [String: SCWindow] = [:]
    private var media: WindowMediaServer?
    private var enumerating = false
    private var controlRequests = 0

    func start() async {
        do {
            let media = try WindowMediaServer { [weak self] fields in
                Task { @MainActor in self?.emit(["type": "observation", "event": "stream.summary", "fields": fields]) }
            }
            self.media = media
            let port = try await media.start()
            emit(["type": "ready", "port": port])
        } catch { emit(["type": "failed"]); exit(3) }
    }
    func handle(_ command: WindowCommand) async {
        guard controlRequests < 8 else { reply(command, error: "Capture provider is busy."); return }
        controlRequests += 1
        defer { controlRequests -= 1 }
        do {
            switch command.method {
            case "catalog":
                guard CGPreflightScreenCaptureAccess() else {
                    sources.removeAll()
                    reply(command, value: ["sources": [], "state": "permissionRequired"]); return
                }
                guard !desktopLocked() else { reply(command, value: ["sources": [], "state": "locked"]); return }
                guard !enumerating else { reply(command, error: "Refreshing Mac windows."); return }
                enumerating = true
                defer { enumerating = false }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                var current: [String: SCWindow] = [:]
                var summaries: [CapturedWindow] = []
                for window in content.windows.prefix(500) {
                    guard let app = window.owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier,
                          window.windowLayer == 0, window.frame.width >= 80, window.frame.height >= 80 else { continue }
                    // Epoch makes sources from an unprovable provider restart unavailable.
                    let id = "window:\(epoch):\(app.processID):\(window.windowID)"
                    current[id] = window
                    summaries.append(CapturedWindow(id: id, title: String((window.title ?? app.applicationName).prefix(256)),
                        application: String(app.applicationName.prefix(128)), contentWidth: window.frame.width, contentHeight: window.frame.height))
                }
                sources = current
                let encoded = try JSONEncoder().encode(summaries)
                reply(command, value: ["sources": try JSONSerialization.jsonObject(with: encoded), "state": "ready"])
            case "open":
                guard CGPreflightScreenCaptureAccess() else { throw ProviderError("Screen Recording permission is required on your Mac.") }
                guard !desktopLocked() else { throw ProviderError("Unlock your Mac to share this window.") }
                guard let id = command.sourceID, let source = sources[id], let media else { throw ProviderError("Source window is unavailable. Select it again on your Mac.") }
                let ticket = await media.issue(source)
                reply(command, value: ["ticket": ticket.uuidString, "contentWidth": source.frame.width, "contentHeight": source.frame.height])
            case "permission":
                _ = CGRequestScreenCaptureAccess()
                reply(command, value: ["granted": CGPreflightScreenCaptureAccess()])
            case "settings":
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                reply(command, value: ["ok": true])
            default: throw ProviderError("Unknown capture operation.")
            }
        } catch { reply(command, error: (error as? ProviderError)?.message ?? "Could not inspect Mac windows.") }
    }
    private func reply(_ command: WindowCommand, value: [String: Any] = [:], error: String? = nil) {
        var result: [String: Any] = ["type": "reply", "id": command.id.uuidString, "value": value]
        if let error { result["error"] = error }
        emit(result)
    }
    private func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.merging(["version": 1]) { _, new in new }), data.count <= 256 * 1024 else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
nonisolated private struct ProviderError: Error { let message: String; init(_ message: String) { self.message = message } }
nonisolated func desktopLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool == true || session?[kCGSessionOnConsoleKey as String] as? Bool != true
}

/// One-time loopback tickets never leave the authenticated companion. The media
/// socket carries binary frames and ACKs; stdout carries bounded control only.
nonisolated private final class WindowMediaServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "slz.window-media")
    private let listener: NWListener
    private var replied = false
    private let observe: @Sendable ([String: String]) -> Void
    private var tickets: [UUID: (SCWindow, TimeInterval)] = [:]
    private var viewers: [UUID: WindowCaptureViewer] = [:]
    init(observe: @escaping @Sendable ([String: String]) -> Void) throws {
        self.observe = observe
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.listener.stateUpdateHandler = { state in
                    guard !self.replied else { return }
                    switch state {
                    case .ready:
                        self.replied = true; continuation.resume(returning: self.listener.port!.rawValue)
                    case .failed(let error): self.replied = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }
    func issue(_ window: SCWindow) async -> UUID {
        await withCheckedContinuation { continuation in
            queue.async {
                self.tickets = self.tickets.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < 10 }
                let ticket = UUID()
                // Opening is bounded independently of socket count.
                if self.tickets.count < 16 { self.tickets[ticket] = (window, ProcessInfo.processInfo.systemUptime) }
                continuation.resume(returning: ticket)
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard viewers.count < 8 else { connection.cancel(); return }
        let id = UUID()
        let viewer = WindowCaptureViewer(id: id, connection: connection, queue: queue, redeem: { [weak self] ticket in
            guard let (window, issued) = self?.tickets.removeValue(forKey: ticket), ProcessInfo.processInfo.systemUptime - issued < 10 else { return nil }
            return window
        }, ended: { [weak self] fields in self?.viewers.removeValue(forKey: id); self?.observe(fields) })
        viewers[id] = viewer
        viewer.start()
    }
}
