import AppKit
import ApplicationServices
import IOKit

@MainActor final class DesktopMonitor {
    var changed: ((String, String) -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastUnlock: Double?
    private var asleep = false
    func start() {
        let distributed = DistributedNotificationCenter.default()
        for (name, state) in [("com.apple.screenIsLocked", "locked"), ("com.apple.screenIsUnlocked", "unlocked")] {
            observers.append(distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.lastUnlock = state == "unlocked" ? uptime() : nil
                    self?.changed?(state, "distributed_notification_undocumented")
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.asleep = true; self?.lastUnlock = nil; self?.changed?("unavailable", name.rawValue) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.asleep = false; self?.lastUnlock = nil; self?.poll() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        poll()
    }
    func poll() {
        guard !asleep else { return }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else {
            changed?("unknown", "no_active_console"); return
        }
        // Deliberately isolated undocumented observation, not a public platform contract.
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        let consoleLocked = root == 0 ? nil : IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        if root != 0 { IOObjectRelease(root) }
        if session["CGSSessionScreenIsLocked"] as? Bool == true || consoleLocked == true {
            lastUnlock = nil
            changed?("locked", "session_or_ioconsole_undocumented")
        } else if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            if locked { lastUnlock = nil }
            changed?(locked ? "locked" : "unlocked", "session_dictionary_undocumented")
        } else if consoleLocked == false {
            changed?("unlocked", "ioconsole_locked_undocumented")
        } else if let lastUnlock, uptime() - lastUnlock < 30 {
            changed?("unlocked", "recent_unlock_or_local_confirmation")
        } else {
            changed?("unknown", "lock_key_absent")
        }
    }
    // Local physical button only. Never exposed over the network. Short lease when the OS
    // omits a lock key; notifications still revoke it immediately. This limitation is visible.
    func confirmLocal() { lastUnlock = uptime(); poll() }
    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}

@MainActor final class AXTarget {
    private var window: AXUIElement?
    private var pid: pid_t = 0
    private var elements: [String: AXUIElement] = [:]
    private(set) var observation = ""
    func bind(pid: pid_t, bounds: CGRect, title: String) throws {
        guard AXIsProcessTrusted() else { throw ProbeFailure("accessibility_denied", "Enable Accessibility for ProbeHost") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = read(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let candidates = windows.filter {
            guard let rect = boundsOf($0) else { return false }
            return abs(rect.minX - bounds.minX) < 3 && abs(rect.minY - bounds.minY) < 3 && abs(rect.width - bounds.width) < 3 && abs(rect.height - bounds.height) < 3
        }
        guard candidates.count == 1 else { throw ProbeFailure("ambiguous_ax_window", "Cannot uniquely associate the captured window with AX") }
        self.pid = pid; window = candidates[0]; elements.removeAll(); observation = ""
    }
    func clear() { window = nil; elements.removeAll(); observation = "" }
    func inspect() throws -> [String: Any] {
        guard AXIsProcessTrusted(), let window else { throw ProbeFailure("ax_unavailable", "Select a target after granting Accessibility") }
        elements.removeAll(); observation = UUID().uuidString
        var rows: [[String: Any]] = []
        var budget = 180
        let deadline = uptime() + 1
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 8, budget > 0, uptime() < deadline else { return }; budget -= 1
            let role = read(element, kAXRoleAttribute) as? String ?? "unknown"
            let title = read(element, kAXTitleAttribute) as? String ?? read(element, kAXDescriptionAttribute) as? String ?? ""
            var actionNames: CFArray?
            AXUIElementCopyActionNames(element, &actionNames)
            let actions = actionNames as? [String] ?? []
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            if !title.isEmpty || actions.contains(kAXPressAction) || settable.boolValue {
                let id = String(rows.count); elements[id] = element
                var row: [String: Any] = ["id": id, "role": role, "title": String(title.prefix(300)), "press": actions.contains(kAXPressAction), "setValue": settable.boolValue]
                if let value = read(element, kAXValueAttribute) as? String { row["value"] = String(value.prefix(500)) }
                rows.append(row)
            }
            for child in read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return ["observation": observation, "elements": rows, "bounds": rectJSON(try rect()), "truncated": budget == 0 || uptime() >= deadline]
    }
    func perform(_ command: Command) throws -> [String: Any] {
        guard AXIsProcessTrusted(), let window else { throw ProbeFailure("ax_unavailable", "AX target unavailable") }
        if command.action == "resize" {
            guard let width = command.width, let height = command.height, width.isFinite, height.isFinite,
                  (320...3840).contains(width), (240...2160).contains(height) else { throw ProbeFailure("invalid_size", "Invalid window dimensions") }
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &writable) == .success, writable.boolValue else { throw ProbeFailure("resize_unsupported", "Window size is not settable") }
            var size = CGSize(width: width, height: height)
            guard let value = AXValueCreate(.cgSize, &size) else { throw ProbeFailure("ax_value", "Cannot form size") }
            try success(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value))
            elements.removeAll(); observation = ""
            return ["bounds": rectJSON(try rect())]
        }
        guard command.observation == observation, let id = command.element, let element = elements[id] else {
            throw ProbeFailure("stale_observation", "Inspect the target before choosing an element")
        }
        if command.action == "press" { try success(AXUIElementPerformAction(element, kAXPressAction as CFString)) }
        else if command.action == "setValue", let text = command.text, text.count <= 4096 {
            try success(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString))
        } else { throw ProbeFailure("unsupported_action", "Use press, setValue, or resize") }
        elements.removeAll(); observation = ""
        return ["accepted": true, "verification": "Observe the actual result; AX acknowledgement alone is not visual verification"]
    }
    func rect() throws -> CGRect {
        guard let window, let result = boundsOf(window) else { throw ProbeFailure("window_gone", "AX target no longer responds") }
        return result
    }
    private func boundsOf(_ element: AXUIElement) -> CGRect? {
        guard let p = read(element, kAXPositionAttribute), let s = read(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, name as CFString, &value); return value
    }
    private func success(_ result: AXError) throws {
        guard result == .success else { throw ProbeFailure("ax_failed", "Accessibility result \(result.rawValue)") }
    }
}
func rectJSON(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
