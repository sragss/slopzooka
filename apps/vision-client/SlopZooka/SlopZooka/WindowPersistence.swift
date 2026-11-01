import Foundation

/// Stable content identity. The system owns scene identity and physical placement.
struct WindowRecord: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case terminal, preview }
    let id: String
    let kind: Kind
    let targetID: String
}

struct WindowReference: Codable, Hashable {
    let hostID: String
    let window: WindowRecord
}

struct WindowLayout: Codable {
    var version = 1
    var revision = 0
    var windows: [WindowRecord] = []

    func validated() throws -> Self {
        guard version == 1, revision >= 0, Set(windows.map(\.id)).count == windows.count else {
            throw CompanionError(message: "Unsupported window layout. Update the companion and headset app together.")
        }
        return self
    }
}

/// The companion is authoritative. Locally we persist only unacknowledged intent,
/// so an offline close or a rebuild during a request cannot resurrect a window.
@MainActor
final class WindowPersistence {
    private struct Change: Codable, Equatable {
        let window: WindowRecord
        let isOpen: Bool
    }
    private let defaults: UserDefaults
    private let key = "windowIntentOutbox.v1"
    private var pending: [String: [String: Change]] = [:]
    private var snapshots: [String: WindowLayout] = [:]
    private var loadError: Error?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { pending = try JSONDecoder().decode([String: [String: Change]].self, from: data) }
            catch { loadError = error }
        }
    }

    func windows(hostID: String) -> [WindowRecord] {
        var records = Dictionary(uniqueKeysWithValues: (snapshots[hostID]?.windows ?? []).map { ($0.id, $0) })
        for change in pending[hostID]?.values ?? [:].values {
            records[change.window.id] = change.isOpen ? change.window : nil
        }
        return records.values.sorted { $0.id < $1.id }
    }

    func set(_ reference: WindowReference, isOpen: Bool) throws {
        if let loadError { throw loadError }
        pending[reference.hostID, default: [:]][reference.window.id] = Change(window: reference.window, isOpen: isOpen)
        try save()
    }

    // Caller serializes synchronization; changes arriving during a request stay in the outbox.
    func synchronize(hostID: String, base: URL) async throws {
        if let loadError { throw loadError }
        let snapshot = try await CompanionAPI.request(WindowLayout.self, base: base, path: "/api/window-layout").validated()
        snapshots[hostID] = snapshot
        let changes = pending[hostID] ?? [:]
        guard !changes.isEmpty else { return }
        let next = WindowLayout(revision: snapshot.revision, windows: windows(hostID: hostID))
        let saved = try await CompanionAPI.request(WindowLayout.self, base: base, path: "/api/window-layout",
            method: "PUT", body: JSONEncoder().encode(next)).validated()
        snapshots[hostID] = saved
        for (id, change) in changes where pending[hostID]?[id] == change { pending[hostID]?.removeValue(forKey: id) }
        if pending[hostID]?.isEmpty == true { pending.removeValue(forKey: hostID) }
        try save()
    }

    private func save() throws {
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
    }
}
