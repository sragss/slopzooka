import Foundation

/// Per-window acknowledgement stays separate from terminal output acknowledgements.
/// The session service owns sequence numbers; screen snapshots never replay sounds.
struct TerminalNotifications: Equatable {
    private(set) var serviceInstanceID: String?
    private(set) var sequence = 0
    private(set) var hasUnread = false

    mutating func receive(sequence: Int, serviceInstanceID: String) -> Bool {
        guard sequence >= 0 else { return false }
        if self.serviceInstanceID != serviceInstanceID {
            self.serviceInstanceID = serviceInstanceID
            self.sequence = 0
            hasUnread = false
        }
        guard sequence > self.sequence else { return false }
        self.sequence = sequence
        hasUnread = true
        return true
    }

    mutating func markRead() { hasUnread = false }
}
