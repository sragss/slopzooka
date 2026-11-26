import Foundation

/// Stable content identity. The system owns scene identity and physical placement.
struct WindowRecord: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case terminal, preview }
    let id: String
    let kind: Kind
    let targetID: String
    var name: String? = nil
    var ownerSessionIds: [String]? = nil

    func sameContent(as other: Self) -> Bool {
        id == other.id && kind == other.kind && targetID == other.targetID
    }
}

struct WindowReference: Codable, Hashable {
    let hostID: String
    let window: WindowRecord

    // Scene identity survives presentation-only renames, including archived scenes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hostID == rhs.hostID && lhs.window.sameContent(as: rhs.window)
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(hostID)
        hasher.combine(window.id)
        hasher.combine(window.kind)
        hasher.combine(window.targetID)
    }
}

struct WindowLayout: Codable {
    var version = 1
    var revision = 0
    var windows: [WindowRecord] = []
    // Transient companion challenge; never part of a window record or local outbox.
    var presentationProbe: String? = nil

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
    private let log = AppLog("window-persistence")
    private struct Change: Codable, Equatable {
        let window: WindowRecord
        let isOpen: Bool
    }
    private let defaults: UserDefaults
    private let key = "windowIntentOutbox.v1"
    // Older apps can still read the open/close outbox without mistaking a
    // pending label for an instruction to open a window.
    private let namesKey = "windowNameOutbox.v1"
    private var pending: [String: [String: Change]] = [:]
    private var pendingNames: [String: [String: WindowRecord]] = [:]
    private var snapshots: [String: WindowLayout] = [:]
    private var loadError: Error?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            let decoder = JSONDecoder()
            if let data = defaults.data(forKey: key) { pending = try decoder.decode([String: [String: Change]].self, from: data) }
            if let data = defaults.data(forKey: namesKey) {
                pendingNames = try decoder.decode([String: [String: WindowRecord]].self, from: data)
            }
        } catch { loadError = error }
    }

    func windows(hostID: String) -> [WindowRecord] {
        var records = Dictionary(uniqueKeysWithValues: (snapshots[hostID]?.windows ?? []).map { ($0.id, $0) })
        for change in pending[hostID]?.values ?? [:].values {
            let id = change.window.id
            let existing = records[id].flatMap { $0.sameContent(as: change.window) ? $0 : nil }
            if change.isOpen {
                records[id] = change.window
                if let existing { records[id]?.name = existing.name }
            } else {
                records[id] = nil
            }
        }
        // Rebase only the label onto the current record. In particular,
        // a remote close or replacement cannot become a local open.
        for record in pendingNames[hostID]?.values ?? [:].values where records[record.id]?.sameContent(as: record) == true {
            records[record.id]?.name = record.name
        }
        return records.values.sorted { $0.id < $1.id }
    }

    func set(_ reference: WindowReference, isOpen: Bool) throws {
        log.info("intent.queued", ["hostId": reference.hostID, "windowId": reference.window.id, "open": String(isOpen)])
        if let loadError { throw loadError }
        let hostID = reference.hostID, window = reference.window
        pending[hostID, default: [:]][window.id] = Change(window: window, isOpen: isOpen)
        try save()
        if !isOpen, pendingNames[hostID]?.removeValue(forKey: window.id) != nil { try saveNames() }
    }

    func rename(_ reference: WindowReference, name: String) throws -> WindowReference {
        if let loadError { throw loadError }
        let hostID = reference.hostID
        let id = reference.window.id
        guard var record = windows(hostID: hostID).first(where: { $0.sameContent(as: reference.window) }) else {
            throw CompanionError(message: "This preview is no longer open.")
        }
        record.name = name
        pendingNames[hostID, default: [:]][id] = record
        try saveNames()
        return WindowReference(hostID: hostID, window: record)
    }

    func isNamePending(_ reference: WindowReference) -> Bool {
        pendingNames[reference.hostID]?[reference.window.id]?.sameContent(as: reference.window) == true
    }

    func hasPendingNames(hostID: String) -> Bool {
        pendingNames[hostID]?.isEmpty == false
    }

    // Caller serializes synchronization; changes arriving during a request stay in the outbox.
    func synchronize(hostID: String, client: CompanionClient, canPresent: () -> Bool = { false }) async throws {
        if let loadError { throw loadError }
        let snapshot = try await client.windowLayout(hostID: hostID).validated()
        if let probe = snapshot.presentationProbe {
            // Evaluate scene readiness after the network reply, not when the request began.
            try? await client.answerPresentationProbe(hostID: hostID, probe: probe, available: canPresent())
        }
        snapshots[hostID] = snapshot
        let changes = pending[hostID] ?? [:]
        let names = pendingNames[hostID] ?? [:]
        guard !changes.isEmpty || !names.isEmpty else { return }
        log.info("layout.saving", ["hostId": hostID, "revision": String(snapshot.revision), "pending": String(changes.count + names.count)])
        let next = WindowLayout(revision: snapshot.revision, windows: windows(hostID: hostID))
        let saved = changes.isEmpty && next.windows == snapshot.windows.sorted { $0.id < $1.id }
            ? snapshot : try await client.saveWindowLayout(hostID: hostID, layout: next).validated()
        snapshots[hostID] = saved
        for (id, change) in changes where pending[hostID]?[id] == change { pending[hostID]?.removeValue(forKey: id) }
        if pending[hostID]?.isEmpty == true { pending.removeValue(forKey: hostID) }
        try save()
        for (id, record) in names where pendingNames[hostID]?[id] == record { pendingNames[hostID]?.removeValue(forKey: id) }
        if pendingNames[hostID]?.isEmpty == true { pendingNames.removeValue(forKey: hostID) }
        if !names.isEmpty { try saveNames() }
        log.info("layout.acknowledged", ["hostId": hostID, "revision": String(saved.revision)])
    }

    private func save() throws {
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
    }

    private func saveNames() throws {
        defaults.set(try JSONEncoder().encode(pendingNames), forKey: namesKey)
    }
}
