import SwiftUI

/// Voice first, local diagnostics, explicit review before any public submission.
struct BugReportView: View {
    let hostID: String?
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var id = UUID().uuidString
    @State private var around = ISO8601DateFormatter().string(from: Date())
    @State private var title = ""
    @State private var description = ""
    @State private var reportID: String?
    @State private var captured = false
    @State private var error: String?
    @State private var state = BugReportState.composing

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Report a bug").font(.title2.weight(.semibold))
                Text("The issue will be public. Logs stay on your Mac and are never attached automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                if state == .composing || state == .preparing {
                    composition.disabled(state == .preparing)
                } else if let draft = state.draft {
                    preview(draft)
                } else if case let .sent(url) = state {
                    Label("Issue created", systemImage: "checkmark.circle")
                    Link("View Issue on GitHub", destination: url)
                    Spacer()
                }
                Text(captured ? (reportID == nil ? "Local snapshot unavailable. You can still report this bug." : "Diagnostic snapshot saved locally on your Mac.") : "Saving local diagnostics…")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = state.message ?? error { Text(message).font(.callout).foregroundStyle(.orange) }
                actions
            }
            .padding(24)
            .navigationBarHidden(true)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 660)
        .interactiveDismissDisabled(state.isSubmitting)
        .task {
            guard !captured else { return }
            startVoice()
            defer { captured = true }
            if let hostID { reportID = try? await client.captureBugReport(hostID: hostID, around: around) }
        }
        .task(id: state) {
            switch state {
            case .preparing:
                do {
                    let draft: BugReportDraft
                    if let hostID {
                        draft = try await client.prepareBugReport(hostID: hostID, title: title, description: description, around: around, reportID: reportID)
                    } else {
                        draft = .offline(title: title, description: description, around: around)
                    }
                    try Task.checkCancellation()
                    state = .reviewing(draft)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = "Could not prepare the report on your Mac. You can still review it without diagnostic metadata."
                    state = .reviewing(.offline(title: title, description: description, around: around))
                }
            case let .submitting(draft):
                do {
                    guard let hostID, let draftID = draft.draftId else { throw URLError(.badServerResponse) }
                    let url = try await client.submitBugReport(hostID: hostID, draftID: draftID)
                    try Task.checkCancellation()
                    state = .sent(url)
                } catch {
                    // Cancellation also leaves an uncertain outcome. Reappearing
                    // must not implicitly start another submission.
                    state.submissionFailed(error)
                }
            default: break
            }
        }
        .onChange(of: voice.captureState) { _, state in
            guard voice.targetID == id else { return }
            switch state {
            case let .failed(message), let .unavailable(message):
                pauseVoice()
                error = message
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pauseVoice() }
        }
        .onDisappear { if voice.targetID == id { voice.stop() } }
    }

    private func preview(_ draft: BugReportDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(draft.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if let account = draft.account { Text("Publish as @\(account)").font(.footnote) }
            if case .unconfirmed = state {
                Link("Check Existing Issues", destination: URL(string: "https://github.com/sragss/slopzooka/issues")!)
            }
            if draft.account == nil {
                Text(draft.browserURL == nil
                    ? "Shorten the description to fit a browser draft link, or copy the report above."
                    : "GitHub credentials aren’t available on your Mac. Continue in your signed-in browser.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Use the first line of your recording, or type a summary", text: $title)
            if voice.targetID == id && (voice.captureState == .listening || voice.captureState == .preparing || voice.captureState == .finishing) {
                ScrollView {
                    Text(voice.hasText ? voice.transcript : "Speak naturally. What happened, and what did you expect?")
                        .foregroundStyle(voice.hasText ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TextEditor(text: $description).accessibilityLabel("Bug description")
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(voice.targetID == id ? voice.statusText : "Speak or type your report").font(.callout)
                    Text("Pauses keep your draft. Review before publishing.").font(.caption).foregroundStyle(.secondary)
                    if voice.targetID == id && voice.captureState == .listening {
                        Button("Edit Text") { pauseVoice() }
                    }
                }
                Spacer()
                VoiceInputButton(voice: voice, id: id, label: voice.targetID == id && voice.captureState == .listening ? "Pause voice input" : "Dictate bug report") {
                    if voice.targetID == id {
                        if voice.captureState == .listening || voice.captureState == .preparing { pauseVoice() }
                        else { voice.stop(); startVoice() }
                    } else { startVoice() }
                }
                .disabled(voice.isSubmitting || voice.captureState == .finishing)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text(isSent ? "Done" : "Cancel")
            }
            .disabled(state.isSubmitting)
            switch state {
            case .composing:
                Spacer()
                Button("Review Public Report") {
                    if voice.targetID == id && voice.hasText { voice.send() }
                    else { prepare(description) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!captured || (voice.targetID == id ? !voice.canSend : description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            case .preparing: ProgressView("Preparing review…")
            case .submitting: ProgressView("Publishing…")
            case let .reviewing(draft):
                Button("Edit") { error = nil; state = .composing }
                Spacer()
                if draft.account != nil {
                    Button("Create Public Issue") { error = nil; state = .submitting(draft) }
                        .buttonStyle(.borderedProminent)
                } else if let url = draft.browserURL {
                    Link("Review on GitHub", destination: url).buttonStyle(.borderedProminent)
                }
            case .rejected:
                Button("Edit") { error = nil; state = .composing }
                Spacer()
                Button("Review Again") { prepare(description) }.buttonStyle(.borderedProminent)
            case let .unconfirmed(draft):
                Spacer()
                if let url = draft.browserURL { Link("Review on GitHub", destination: url) }
            case .sent: Spacer()
            }
        }
        .buttonStyle(.bordered)
    }

    private var isSent: Bool {
        if case .sent = state { return true }
        return false
    }

    private func startVoice() {
        if !voice.activateDraft(id, text: description, onReview: { prepare($0) }) {
            error = "Your existing voice draft is paused and kept. Finish or discard it to dictate this report, or type here."
        } else { error = nil }
    }

    private func pauseVoice() {
        guard voice.targetID == id else { return }
        voice.pause()
        description = voice.transcript
        voice.stop()
    }

    private func prepare(_ text: String) {
        description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = String(description.prefix(120)).components(separatedBy: .newlines).first ?? "Bug report"
        }
        guard title.count <= 120, !description.isEmpty, description.count <= 4000 else {
            error = "Keep the summary within 120 characters and the description within 4,000. Your draft is kept."
            return
        }
        error = nil
        state = .preparing
    }
}
