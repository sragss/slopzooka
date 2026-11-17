import SwiftUI
import Combine

struct CoordinatorView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var launcher: LauncherState
    @StateObject private var state = CoordinatorState()
    @State private var draft = ""
    @State private var selectedSession = ""

    private var selectedWorker: CoordinatorWorker? { state.snapshot?.workers.first { $0.sessionId == selectedSession } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask SlopZooka").font(.headline)
            Text("Launch a workspace or send a task to its coding agent.").font(.footnote).foregroundStyle(.secondary)
            Picker("Destination", selection: $selectedSession) {
                Text("Global").tag("")
                ForEach(state.snapshot?.workers ?? []) { worker in
                    Text(name(worker)).tag(worker.sessionId)
                }
            }
            TextField("Launch Poncho2 with admin and iOS open…", text: $draft, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                Button("Send") {
                    guard let hostID = client.current?.id else { return }
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let worker = selectedWorker
                    Task { await state.submit(client: client, hostID: hostID, text: text, worker: worker) }
                }.buttonStyle(.borderedProminent)
                    .disabled(state.snapshot?.available != true || state.submitting || state.snapshot?.status == "running" || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if state.snapshot?.requestId != nil {
                    Button("Stop this request", role: .destructive) {
                        guard let hostID = client.current?.id else { return }
                        Task { await state.stop(client: client, hostID: hostID) }
                    }.buttonStyle(.bordered)
                }
            }
            if let message = state.snapshot?.message { Text(message).foregroundStyle(.secondary) }
            if let error = state.error { Text(error).foregroundStyle(.orange).font(.footnote) }
            if let activity = state.snapshot?.activity { HStack { ProgressView(); Text(activity).font(.footnote) } }
            if let reply = state.snapshot?.reply, !reply.isEmpty { Text(reply).textSelection(.enabled) }
            ForEach(state.snapshot?.workers ?? []) { worker in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(name(worker)).font(.subheadline.bold()); Spacer(); Text(worker.status).font(.caption).foregroundStyle(.secondary) }
                    if let error = worker.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if let question = worker.question {
                        Text(question.title).font(.subheadline.bold())
                        DisclosureGroup("Review requested action") { Text(question.details).font(.caption.monospaced()).textSelection(.enabled) }
                        HStack {
                            Button("Allow once") { answer(worker, accept: true) }.buttonStyle(.bordered)
                            Button("Decline", role: .cancel) { answer(worker, accept: false) }.buttonStyle(.bordered)
                        }
                    }
                    if let result = worker.result { DisclosureGroup("Latest agent response") { Text(result).font(.footnote).textSelection(.enabled) } }
                }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: state.snapshot?.workers.map(\.sessionId)) { _, _ in
            guard let hostID = client.current?.id else { return }
            Task { await launcher.loadWorkspaces(hostID: hostID) }
        }
        .task(id: client.current?.id) {
            let hostID = client.current?.id
            state.observe(hostID: hostID)
            selectedSession = ""
            guard let hostID else { return }
            while !Task.isCancelled {
                await state.refresh(client: client, hostID: hostID)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func name(_ worker: CoordinatorWorker) -> String {
        launcher.recentWorkspaces.first { $0.workspaceId == worker.workspaceId }?.name ?? worker.workspaceId
    }
    private func answer(_ worker: CoordinatorWorker, accept: Bool) {
        guard let hostID = client.current?.id else { return }
        Task { await state.answer(client: client, hostID: hostID, worker: worker, accept: accept) }
    }
}
