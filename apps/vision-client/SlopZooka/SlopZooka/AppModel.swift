import Foundation
import Combine

struct TerminalSessionState: Identifiable {
    let id: String
    var payload: TerminalWindowPayload
    var isPresented: Bool
    var isFocused: Bool
    var loadState: TerminalLoadState
    var pendingInput: TerminalInjectedInput?
    let createdAt: Date
    var lastFocusedAt: Date?
}

struct TerminalInjectedInput {
    let token: Int
    let text: String
    let sendReturn: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private var terminalPayloads: [String: TerminalWindowPayload] = [:]
    @Published private var terminalSessions: [String: TerminalSessionState] = [:]
    @Published private var previewPayloads: [String: PreviewWindowPayload] = [:]

    func registerTerminal(_ payload: TerminalWindowPayload) {
        terminalPayloads[payload.id] = payload

        if var existing = terminalSessions[payload.id] {
            existing.payload = payload
            terminalSessions[payload.id] = existing
            return
        }

        terminalSessions[payload.id] = TerminalSessionState(
            id: payload.id,
            payload: payload,
            isPresented: false,
            isFocused: false,
            loadState: .idle,
            pendingInput: nil,
            createdAt: Date(),
            lastFocusedAt: nil
        )
    }

    func terminalPayload(for id: String) -> TerminalWindowPayload? {
        terminalPayloads[id]
    }

    func terminalSession(for id: String) -> TerminalSessionState? {
        terminalSessions[id]
    }

    var openTerminalSessions: [TerminalSessionState] {
        terminalSessions.values
            .sorted { lhs, rhs in
                if lhs.isFocused != rhs.isFocused {
                    return lhs.isFocused && !rhs.isFocused
                }

                if lhs.isPresented != rhs.isPresented {
                    return lhs.isPresented && !rhs.isPresented
                }

                let lhsDate = lhs.lastFocusedAt ?? lhs.createdAt
                let rhsDate = rhs.lastFocusedAt ?? rhs.createdAt
                return lhsDate > rhsDate
            }
    }

    var activeTerminalSessionID: String? {
        openTerminalSessions.first(where: \.isFocused)?.id
    }

    func markTerminalPresented(id: String, isPresented: Bool) {
        guard var session = terminalSessions[id] else {
            return
        }

        session.isPresented = isPresented
        if !isPresented {
            session.isFocused = false
        }
        terminalSessions[id] = session
    }

    func markTerminalFocused(id: String, isFocused: Bool) {
        guard terminalSessions[id] != nil else {
            return
        }

        if isFocused {
            for key in terminalSessions.keys {
                guard var session = terminalSessions[key] else {
                    continue
                }
                session.isFocused = key == id
                if key == id {
                    session.lastFocusedAt = Date()
                }
                terminalSessions[key] = session
            }
            return
        }

        guard var session = terminalSessions[id] else {
            return
        }
        session.isFocused = false
        terminalSessions[id] = session
    }

    func updateTerminalLoadState(id: String, loadState: TerminalLoadState) {
        guard var session = terminalSessions[id] else {
            return
        }

        session.loadState = loadState
        terminalSessions[id] = session
    }

    func queueTerminalInput(id: String, text: String, sendReturn: Bool = true) {
        guard var session = terminalSessions[id] else {
            return
        }

        let nextToken = (session.pendingInput?.token ?? 0) + 1
        session.pendingInput = TerminalInjectedInput(token: nextToken, text: text, sendReturn: sendReturn)
        terminalSessions[id] = session
    }

    func removeTerminal(id: String) {
        terminalPayloads.removeValue(forKey: id)
        terminalSessions.removeValue(forKey: id)
    }

    func registerPreview(_ payload: PreviewWindowPayload) {
        previewPayloads[payload.id] = payload
    }

    func previewPayload(for id: String) -> PreviewWindowPayload? {
        previewPayloads[id]
    }

    func removePreview(id: String) {
        previewPayloads.removeValue(forKey: id)
    }
}
