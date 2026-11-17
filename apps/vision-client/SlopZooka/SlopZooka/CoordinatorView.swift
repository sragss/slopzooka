import SwiftUI

struct CoordinatorView: View {
    @ObservedObject var state: CoordinatorState
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var launcher: LauncherState
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.scenePhase) private var phase
    @State private var showingDetails = false
    @State private var followingLatest = true
    @State private var microphoneReady = SpeechCaptureController.hasPermissions
    @State private var preparingMicrophone = false
    @State private var permissionError: String?

    private var contextLabel: String {
        if let id = state.context?.sessionID, let terminal = windows.terminalPayload(for: id) { return terminal.displayTitle }
        return state.context?.label ?? "Global"
    }
    private var anotherDraft: Bool { voice.targetID != nil && voice.targetID != CoordinatorState.sceneID && voice.hasText }
    private var canSpeak: Bool { microphoneReady && !anotherDraft && state.canReceiveVoice(client: client) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ask SlopZooka").font(.title3.weight(.semibold))
                Spacer()
                Button("Details", systemImage: "ellipsis") { showingDetails = true }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            HStack {
                Text(contextLabel).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if state.context?.workspaceID != nil {
                    Button("Global") {
                        if let hostID = state.context?.hostID { state.select(CoordinatorContext(hostID: hostID)) }
                    }
                    .font(.footnote).buttonStyle(.borderless)
                    .disabled(!state.canChangeContext() || state.submitting)
                }
            }
            HStack(spacing: 8) {
                if state.isWorking { ProgressView().controlSize(.small) }
                Text(state.statusText).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            conversation
            if anotherDraft { Text("Finish or cancel the voice draft in your other window.").font(.footnote).foregroundStyle(.secondary) }
            if let error = state.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if state.needsApproval {
                Button("Review requested action") { showingDetails = true }.buttonStyle(.borderedProminent)
            }
            if let permissionError { Text(permissionError).font(.footnote).foregroundStyle(.orange).lineLimit(2) }
            HStack {
                if !microphoneReady {
                    Button(preparingMicrophone ? "Getting ready…" : "Enable Microphone") { Task { await prepareMicrophone() } }
                        .disabled(preparingMicrophone).buttonStyle(.bordered)
                } else if state.canStop {
                    Button("Stop", role: .destructive) {
                        guard let hostID = state.context?.hostID else { return }
                        Task { await state.stop(client: client, hostID: hostID) }
                    }.buttonStyle(.bordered).accessibilityLabel("Stop the latest coordinator request")
                }
                Spacer()
            }.frame(height: 96)
        }
        .padding(24).frame(width: 520, height: 560)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        .modifier(TerminalVoiceOverlay(id: CoordinatorState.sceneID, isAvailable: canSpeak, canRename: false, mode: .coordinator))
        .sheet(isPresented: $showingDetails) { details }
        .onAppear { selectInitialContext() }
        .onChange(of: client.current?.id) { _, _ in selectInitialContext() }
        .onChange(of: phase) { _, next in
            if next == .active { microphoneReady = SpeechCaptureController.hasPermissions }
        }
        .onDisappear {
            voice.closeInput(CoordinatorState.sceneID)
        }
        .task(id: state.context?.hostID) {
            guard let hostID = state.context?.hostID else { return }
            while !Task.isCancelled {
                await state.refresh(client: client, hostID: hostID)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: state.snapshot?.workers.map(\.sessionId)) { _, _ in
            guard let hostID = state.context?.hostID else { return }
            Task { await launcher.loadWorkspaces(hostID: hostID) }
        }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if state.conversation.isEmpty {
                        Text(state.responseText).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(state.conversation) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(turn.text).textSelection(.enabled)
                                .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if let reply = turn.reply { CoordinatorMarkdown(text: reply) }
                            if let result = turn.resultExcerpt {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Agent result").font(.caption).foregroundStyle(.secondary)
                                    CoordinatorMarkdown(text: result)
                                }
                            }
                            if !turn.progress.isEmpty { Text(turn.progress).font(.caption).foregroundStyle(.secondary) }
                        }.id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(.vertical, 4)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, atBottom in followingLatest = atBottom }
            .onAppear { reader.scrollTo("latest", anchor: .bottom) }
            .onChange(of: state.conversation.last) { _, _ in
                if followingLatest { reader.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: state.submitting) { _, submitting in
                if submitting { followingLatest = true; reader.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Coordinator details").font(.headline); Spacer(); Button("Done") { showingDetails = false } }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reply = state.snapshot?.reply {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last coordinator reply").font(.caption).foregroundStyle(.secondary)
                            CoordinatorMarkdown(text: reply)
                        }
                    }
                    ForEach(state.snapshot?.workers ?? []) { worker in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(launcher.recentWorkspaces.first { $0.workspaceId == worker.workspaceId }?.name ?? "Coding agent").bold()
                                Spacer()
                                Text(worker.status).foregroundStyle(.secondary)
                            }
                            if let error = worker.error { Text(error).foregroundStyle(.orange) }
                            if let question = worker.question {
                                Text(question.title).bold()
                                Text(question.details).font(.caption.monospaced()).textSelection(.enabled)
                                HStack {
                                    Button("Allow once") { answer(worker, accept: true) }.buttonStyle(.bordered)
                                    Button("Decline", role: .cancel) { answer(worker, accept: false) }.buttonStyle(.bordered)
                                }
                            }
                            if let result = worker.result { CoordinatorMarkdown(text: result) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 560, height: 520)
    }
    private func selectInitialContext() {
        guard state.context == nil, let host = client.current else { return }
        state.select(CoordinatorContext(hostID: host.id))
    }
    private func prepareMicrophone() async {
        preparingMicrophone = true
        defer { preparingMicrophone = false }
        do {
            try await SpeechCaptureController.requestPermissions()
            microphoneReady = true
            permissionError = nil
        } catch { permissionError = "\(error.localizedDescription) Check SlopZooka's permissions in Settings." }
    }
    private func answer(_ worker: CoordinatorWorker, accept: Bool) {
        guard let hostID = state.context?.hostID else { return }
        Task { await state.answer(client: client, hostID: hostID, worker: worker, accept: accept) }
    }
}
