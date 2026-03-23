import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private var terminalPayloads: [String: TerminalWindowPayload] = [:]

    func registerTerminal(_ payload: TerminalWindowPayload) {
        terminalPayloads[payload.id] = payload
    }

    func terminalPayload(for id: String) -> TerminalWindowPayload? {
        terminalPayloads[id]
    }

    func removeTerminal(id: String) {
        terminalPayloads.removeValue(forKey: id)
    }
}
