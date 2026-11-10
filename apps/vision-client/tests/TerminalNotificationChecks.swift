import Foundation

@main
struct TerminalNotificationChecks {
    static func main() {
        var notifications = TerminalNotifications()
        precondition(!notifications.receive(sequence: 0, serviceInstanceID: "first"))
        precondition(!notifications.hasUnread)
        precondition(notifications.receive(sequence: 1, serviceInstanceID: "first"))
        precondition(notifications.hasUnread)
        notifications.markRead()
        precondition(!notifications.hasUnread)
        precondition(!notifications.receive(sequence: 1, serviceInstanceID: "first"), "reload cannot mark a read notification unread")
        precondition(!notifications.receive(sequence: 0, serviceInstanceID: "first"), "late replay cannot roll state back")
        precondition(!notifications.hasUnread)
        precondition(notifications.receive(sequence: 5, serviceInstanceID: "first"), "checkpoint recovers missed alerts")
        precondition(notifications.hasUnread)
        precondition(!notifications.receive(sequence: 0, serviceInstanceID: "replacement"))
        precondition(!notifications.hasUnread, "replacement service cannot inherit old unread state")
        precondition(notifications.receive(sequence: 1, serviceInstanceID: "replacement"))
        var otherWindow = TerminalNotifications()
        precondition(!otherWindow.hasUnread, "unread state belongs to one window")
        otherWindow.markRead()
        precondition(notifications.hasUnread, "selecting another window cannot clear this one")
        print("PASS: notification acknowledgement, replay deduplication, checkpoints, replacement services, and window isolation")
    }
}
