import Foundation
import Combine

@MainActor
final class CoordinatorState: ObservableObject {
    @Published var snapshot: CoordinatorSnapshot?
    @Published var error: String?
    @Published private(set) var submitting = false
    private var hostID: String?
    private var generation = UUID()
    private var revision = 0
    private var pending: (id: String, text: String, session: String?)?

    func observe(hostID: String?) {
        guard self.hostID != hostID else { return }
        self.hostID = hostID
        generation = UUID()
        snapshot = nil
        error = nil
        pending = nil
        submitting = false
    }
    func refresh(client: CompanionClient, hostID: String) async {
        guard !submitting else { return }
        let current = generation
        let observedRevision = revision
        do {
            let value = try await client.coordinatorStatus(hostID: hostID)
            guard current == generation, self.hostID == hostID, observedRevision == revision else { return }
            snapshot = value
            if value.requestId == pending?.id { pending = nil }
            error = nil
        } catch {
            guard current == generation, observedRevision == revision else { return }
            self.error = error.localizedDescription
        }
    }
    func submit(client: CompanionClient, hostID: String, text: String, worker: CoordinatorWorker?) async {
        guard !submitting else { return }
        revision += 1
        let current = generation
        let submittedRevision = revision
        submitting = true
        defer { if current == generation { submitting = false } }
        if pending?.text != text || pending?.session != worker?.sessionId {
            pending = (UUID().uuidString, text, worker?.sessionId)
        }
        guard let request = pending else { return }
        do {
            let value = try await client.coordinatorSubmit(hostID: hostID, requestID: request.id, text: text,
                workspaceID: worker?.workspaceId, sessionID: worker?.sessionId)
            guard current == generation, submittedRevision == revision else { return }
            snapshot = value
            pending = nil
            error = nil
        } catch {
            guard current == generation, submittedRevision == revision else { return }
            self.error = "Could not confirm submission. Check the current activity before trying again. \(error.localizedDescription)"
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
            snapshot = value
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
            snapshot = value
        } catch { if current == generation, mutation == revision { self.error = error.localizedDescription } }
    }
}
