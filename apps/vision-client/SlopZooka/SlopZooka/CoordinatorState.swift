import Foundation
import Combine

struct CoordinatorContext: Equatable {
    let hostID: String
    var workspaceID: String?
    var sessionID: String?
    var label = "Global"
}

/// Ephemeral command context and response state, shared by the one utility scene.
/// Voice owns drafts and immutable submission IDs; the gateway owns presentation.
@MainActor
final class CoordinatorState: ObservableObject {
    static let sceneID = "coordinator"
    @Published private(set) var context: CoordinatorContext?
    @Published private(set) var snapshot: CoordinatorSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var pendingTurn: CoordinatorTurn?
    @Published private(set) var submitting = false
    @Published private(set) var sceneActive = false
    var canChangeContext: () -> Bool = { true }
    private var presenter: UUID?
    private var generation = UUID()
    private var revision = 0

    @discardableResult
    func select(_ context: CoordinatorContext?) -> Bool {
        guard canChangeContext(), !submitting else { return false }
        guard self.context != context else { return true }
        if self.context?.hostID != context?.hostID {
            generation = UUID()
            snapshot = nil
            pendingTurn = nil
            error = nil
        }
        self.context = context
        revision += 1
        return true
    }
    func observeScene(_ id: UUID, active: Bool) {
        if active { presenter = id; sceneActive = true }
        else if presenter == id { presenter = nil; sceneActive = false }
    }
    private func isAvailable(client: CompanionClient) -> Bool {
        guard sceneActive, let context, snapshot?.available == true,
            !submitting, client.pairedHostIDs.contains(context.hostID) else { return false }
        return client.current?.id != context.hostID || client.isReady
    }
    func canReceiveVoice(client: CompanionClient) -> Bool {
        isAvailable(client: client) && snapshot?.status != "running"
    }
    func canSubmit(client: CompanionClient, command: TerminalVoiceCommand) -> Bool {
        guard command.destination == .coordinator, command.targetID == Self.sceneID,
            isAvailable(client: client) else { return false }
        // A lost reply can be confirmed while Pi is busy with that request.
        // New utterances still wait; the host verifies the retried payload.
        return snapshot?.status != "running" || snapshot?.requestId == command.commandID
            || snapshot?.turns?.contains(where: { $0.requestId == command.commandID }) == true
    }
    func refresh(client: CompanionClient, hostID: String) async {
        guard !submitting, context?.hostID == hostID else { return }
        let current = generation
        let observedRevision = revision
        do {
            let value = try await client.coordinatorStatus(hostID: hostID)
            guard current == generation, context?.hostID == hostID, observedRevision == revision else { return }
            apply(value)
        } catch {
            guard current == generation, observedRevision == revision else { return }
            self.error = error.localizedDescription
        }
    }
    func submit(client: CompanionClient, command: TerminalVoiceCommand) async throws {
        guard let captured = context, canSubmit(client: client, command: command) else {
            throw CompanionError(message: "Coordinator is not available right now. Reconnect and retry.")
        }
        revision += 1
        let current = generation
        let submittedRevision = revision
        submitting = true
        pendingTurn = CoordinatorTurn(requestId: command.commandID, text: command.text, workspaceId: captured.workspaceID, sessionId: captured.sessionID, status: "sending")
        defer { if current == generation { submitting = false } }
        do {
            let value = try await client.coordinatorSubmit(hostID: captured.hostID, requestID: command.commandID, text: command.text,
                workspaceID: captured.workspaceID, sessionID: captured.sessionID)
            guard current == generation, submittedRevision == revision else { return }
            pendingTurn = nil
            apply(value)
        } catch {
            if current == generation, submittedRevision == revision {
                pendingTurn?.status = "unconfirmed"
                self.error = "Could not confirm submission. Retry keeps the same request."
            }
            throw error
        }
    }
    func stop(client: CompanionClient, hostID: String) async {
        revision += 1
        let current = generation
        let mutation = revision
        do {
            let value = try await client.coordinatorStop(hostID: hostID)
            guard current == generation, mutation == revision else { return }
            revision += 1
            apply(value)
        } catch { if current == generation, mutation == revision { self.error = error.localizedDescription } }
    }
    func answer(client: CompanionClient, hostID: String, worker: CoordinatorWorker, accept: Bool) async {
        guard let question = worker.question else { return }
        revision += 1
        let current = generation
        let mutation = revision
        do {
            let value = try await client.coordinatorAnswer(hostID: hostID, sessionID: worker.sessionId, questionID: question.id, accept: accept)
            guard current == generation, mutation == revision else { return }
            revision += 1
            apply(value)
        } catch { if current == generation, mutation == revision { self.error = error.localizedDescription } }
    }

    private func apply(_ value: CoordinatorSnapshot) {
        snapshot = value
        if value.turns?.contains(where: { $0.id == pendingTurn?.id }) == true { pendingTurn = nil }
        error = nil
    }

    var conversation: [CoordinatorTurn] {
        let turns = snapshot?.turns ?? []
        guard let pendingTurn, !turns.contains(where: { $0.id == pendingTurn.id }) else { return turns }
        return turns + [pendingTurn]
    }

    var requestWorkers: [CoordinatorWorker] {
        let ids = Set(snapshot?.workerSessionIds ?? [])
        return snapshot?.workers.filter { ids.contains($0.sessionId) } ?? []
    }
    var needsApproval: Bool { snapshot?.workers.contains { $0.question != nil } == true }
    var isWorking: Bool {
        snapshot?.status == "running" || requestWorkers.contains { ["starting", "running", "waiting"].contains($0.status) }
    }
    var canStop: Bool { snapshot?.requestId != nil && (isWorking || snapshot?.status == "failed") }
    var statusText: String {
        if submitting { return "Sending…" }
        if needsApproval { return "Approval needed" }
        guard let snapshot else { return context == nil ? "Connect to your Mac" : "Connecting…" }
        if !snapshot.available { return "Not available right now" }
        if snapshot.status == "stopped" { return isWorking ? "Stopping…" : "Stopped" }
        if snapshot.status == "running" { return snapshot.activity ?? "Working…" }
        if snapshot.status == "failed" || requestWorkers.contains(where: { ["failed", "unavailable"].contains($0.status) }) { return "Needs attention" }
        if isWorking { return "Agent working…" }
        if requestWorkers.contains(where: { $0.status == "interrupted" }) { return "Interrupted" }
        return snapshot.requestId == nil ? "Ready" : "Done"
    }
    var responseText: String {
        if let error { return error }
        guard let snapshot else { return "Hold the microphone and say what you need." }
        if !snapshot.available { return snapshot.message ?? "Reconnect to your Mac and try again." }
        if needsApproval { return "Review the requested action before the agent continues." }
        if snapshot.status == "stopped" { return isWorking ? "Cancellation sent. Waiting for the agent to stop." : "Your apps, windows and terminals remain open." }
        if snapshot.status == "failed" { return snapshot.reply ?? "The request could not finish. Open Details to check its state." }
        if isWorking { return "You can follow the work in its terminal." }
        if let error = requestWorkers.compactMap(\.error).first { return error }
        if requestWorkers.count == 1, let worker = requestWorkers.first, worker.status == "completed", let result = worker.result { return result }
        if requestWorkers.count > 1, requestWorkers.allSatisfy({ $0.status == "completed" }) { return "Tasks completed in \(requestWorkers.count) agents. Open Details for their results." }
        return snapshot.reply ?? "Hold the microphone and say what you need."
    }
}
