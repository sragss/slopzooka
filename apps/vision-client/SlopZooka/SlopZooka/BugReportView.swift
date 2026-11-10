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
    @State private var draft: BugReportDraft?
    @State private var error: String?
    @State private var stage = Stage.compose
    @State private var issueURL: URL?
    @State private var attempted = false
    private enum Stage: Equatable { case compose, preparing, review, publishing, sent }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Describe what went wrong").font(.title2)
                Text("The issue will be public. Logs stay on your Mac and are never attached automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                if stage == .compose {
                    composition
                } else if let draft {
                    Text(title).font(.headline)
                    ScrollView {
                        Text(draft.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    if let account = draft.account { Text("Publish as @\(account)").font(.callout) }
                    if let issueURL { Link("View Issue on GitHub", destination: issueURL) }
                    else {
                        if attempted {
                            Link("Check Existing Issues", destination: URL(string: "https://github.com/sragss/slopzooka/issues")!)
                        }
                        if let browserURL = draft.browserURL, draft.account == nil || attempted {
                            Link("Review on GitHub", destination: browserURL)
                        }
                    }
                    if stage == .review && draft.account == nil {
                        if draft.browserURL == nil {
                            Text("Shorten the description to fit a browser draft link, or copy the report above.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("GitHub credentials aren’t available on your Mac. Continue in your signed-in browser.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(captured ? (reportID == nil ? "Local snapshot unavailable. You can still report this bug." : "Diagnostic snapshot saved locally on your Mac.") : "Saving local diagnostics…")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                actions
            }
            .padding(28)
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .sent ? "Done" : "Cancel") { dismiss() }
                        .disabled(stage == .publishing)
                }
            }
        }
        .frame(width: 620, height: 660)
        .interactiveDismissDisabled(stage == .publishing)
        .task {
            startVoice()
            defer { captured = true }
            if let hostID { reportID = try? await client.captureBugReport(hostID: hostID, around: around) }
        }
        .task(id: stage) {
            do {
                if stage == .preparing {
                    let prepared: BugReportDraft
                    if let hostID {
                        prepared = try await client.prepareBugReport(hostID: hostID, title: title, description: description, around: around, reportID: reportID)
                    } else {
                        prepared = .offline(title: title, description: description, around: around)
                    }
                    try Task.checkCancellation()
                    draft = prepared
                    stage = .review
                } else if stage == .publishing, let hostID, let draftID = draft?.draftId {
                    let url = try await client.submitBugReport(hostID: hostID, draftID: draftID)
                    try Task.checkCancellation()
                    issueURL = url
                    stage = .sent
                }
            } catch {
                guard !Task.isCancelled else { return }
                if stage == .publishing {
                    self.error = "Could not publish or confirm this report. Check existing issues before submitting again."
                    stage = .review
                }
                else {
                    self.error = "Could not prepare the report on your Mac. You can still review it without diagnostic metadata."
                    draft = .offline(title: title, description: description, around: around)
                    stage = .review
                }
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

    private var composition: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Summary (or use the first line of your recording)", text: $title)
                .textFieldStyle(.roundedBorder)
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
        HStack {
            if stage == .review && !attempted { Button("Edit") { draft = nil; stage = .compose } }
            Spacer()
            if stage == .compose {
                Button("Review Public Report") {
                    if voice.targetID == id && voice.hasText { voice.send() }
                    else { prepare(description) }
                }
                .disabled(!captured || (voice.targetID == id ? !voice.canSend : description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            } else if stage == .preparing || stage == .publishing {
                ProgressView(stage == .preparing ? "Preparing review…" : "Publishing…")
            } else if stage == .review && draft?.account != nil && !attempted {
                Button("Create Public Issue") { attempted = true; error = nil; stage = .publishing }
                    .buttonStyle(.borderedProminent)
            }
        }
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
        stage = .preparing
    }
}
