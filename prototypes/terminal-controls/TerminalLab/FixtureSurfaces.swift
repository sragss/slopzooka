import SwiftUI

/// The production title’s editor needs a real WindowGateway. The lab supplies voice naming against its fixture.
struct FixtureTerminalTitle: View {
    @Environment(LabModel.self) private var lab
    @EnvironmentObject private var voice: TerminalVoiceController

    var body: some View {
        HStack(spacing: 12) {
            if let project = lab.payload.projectName {
                Text(project).lineLimit(1)
                Divider()
            }
            if let workspace = lab.payload.workspaceName {
                name(workspace, target: .workspace)
                Divider()
            }
            name(lab.payload.title, target: .window)
        }
        .font(.system(size: 28, weight: .bold, design: .rounded))
        .padding(.horizontal, 18)
        .frame(height: 54)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        .accessibilityAddTraits(.isHeader)
    }

    private func name(_ title: String, target: TerminalVoiceController.NameTarget) -> some View {
        Button {
            voice.activateRename(lab.payload.id, target: target)
        } label: {
            Text(title)
                .lineLimit(1)
                .frame(minHeight: 54)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!lab.canRename || voice.isSubmitting)
        .accessibilityLabel("Rename \(target.rawValue), \(title)")
    }
}

struct FixtureTerminalSurface: View {
    @Environment(LabModel.self) private var lab
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private let foreground = Color(red: 231 / 255, green: 237 / 255, blue: 247 / 255)
    private let muted = Color(red: 153 / 255, green: 167 / 255, blue: 188 / 255)

    var body: some View {
        let fontSize = 16 * TerminalZoom.scale(steps: lab.zoom)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.12) {
                    if lab.isShell { shell }
                    else { agent }
                    ForEach(Array(lab.output.enumerated()), id: \.offset) { _, line in
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    if lab.session != .ended {
                        if lab.focusedKeyboard {
                            HStack(spacing: 6) {
                                Text("›")
                                TextField("Terminal input", text: $input, prompt: Text("Type a command"))
                                    .textFieldStyle(.plain)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .focused($inputFocused)
                                    .onSubmit {
                                        lab.submitKeyboard(input)
                                        input = ""
                                        inputFocused = true
                                    }
                            }
                        } else {
                            Text("›  ▋").foregroundStyle(muted)
                                .accessibilityLabel("Terminal prompt")
                        }
                    }
                    Color.clear.frame(height: 1).id("prompt").accessibilityHidden(true)
                }
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: lab.output) { _, _ in reader.scrollTo("prompt", anchor: .bottom) }
            .onChange(of: lab.focusedKeyboard) { _, requested in
                inputFocused = requested
                if requested { reader.scrollTo("prompt", anchor: .bottom) }
            }
            .onChange(of: inputFocused) { _, focused in
                if !focused { lab.focusedKeyboard = false }
            }
        }
        .background(Color(red: 5 / 255, green: 7 / 255, blue: 11 / 255))
        .contentShape(Rectangle())
        .onTapGesture {
            if lab.session.acceptsControls { lab.focusedKeyboard = true }
        }
        .overlay(alignment: .topLeading) {
            if lab.session == .readOnly {
                Text("Read only")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(muted)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(red: 12 / 255, green: 16 / 255, blue: 24 / 255).opacity(0.84), in: Capsule())
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .preferredColorScheme(.dark)
    }

    private var agent: some View {
        Group {
            Text("╭─────────────────────────────────────────────╮").foregroundStyle(muted)
            Text("│  >_ OpenAI Codex                            │")
            Text("│                                             │").foregroundStyle(muted)
            Text("│  directory: ~/slopzooka/terminal-controls   │")
            Text("╰─────────────────────────────────────────────╯").foregroundStyle(muted)
            Text(" ")
            Text("› Check the terminal keyboard and voice controls.").foregroundStyle(muted)
            Text(" ")
            Text("• I’ll run the keyboard checks and review the native terminal controls.")
            Text(" ")
            Text("  Ran pnpm test:terminal-keyboard").foregroundStyle(.green)
            Text("  └─ WebKit input, zoom, and resize checks passed").foregroundStyle(muted)
            Text(" ")
            Text("  The native actions popover uses separate gaze targets for zoom and session actions.")
            Text("  Next I’ll check the hold-to-talk flow in the terminal window.")
            Text(" ")
            Text(" /  for commands").foregroundStyle(muted)
        }
    }

    private var shell: some View {
        Group {
            Text("Last login: Thu Nov 26 14:35:18 on ttys004").foregroundStyle(muted)
            Text("slopzooka/terminal-controls % git status --short")
            Text("slopzooka/terminal-controls % pwd")
            Text("/Users/demo/workspaces/slopzooka/terminal-controls")
        }
    }
}

struct FixtureFrontends: View {
    @Environment(LabModel.self) private var lab
    let openPreview: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lab.frontends == .warning {
                DisclosureGroup("Discovery notice") {
                    Text("The Mac could not refresh its frontend catalog. Previously discovered frontends are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.orange)
            }
            if lab.frontends == .empty {
                Text("No frontends for this worktree yet. Ask your agent to start a web app on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                row("SlopZooka Dashboard", status: lab.frontends == .starting ? "Waiting for response" : nil)
                row("Design System", status: lab.frontends == .starting ? "Stopped" : nil)
            }
        }
    }

    private func row(_ title: String, status: String?) -> some View {
        let restricted = lab.frontends == .restricted
        return Button { openPreview(title) } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 40).background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if restricted || status != nil {
                        Text(restricted ? "Web previews require Local Network." : (status ?? ""))
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("slopzooka").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(restricted || lab.session == .disconnected || lab.session == .connecting)
        .hoverEffectDisabled()
        .modifier(LauncherRowSurface())
    }
}

struct FixturePreview: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(title, systemImage: "globe").font(.title2.bold())
                Spacer()
                Button("Close Preview", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
            Spacer()
            LabeledContent("Frontend", value: "Ready")
            LabeledContent("Worktree", value: "terminal-controls")
            LabeledContent("Source", value: "Development server")
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewDictationBar: View {
    @Environment(LabModel.self) private var lab
    @EnvironmentObject private var voice: TerminalVoiceController

    private var active: Bool { voice.targetID == LabModel.reviewID }
    private var ready: Bool { lab.reviewReady }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if active {
                VStack(alignment: .leading, spacing: 10) {
                    VoiceTranscript(text: voice.hasText ? voice.transcript : "Speak naturally.", isPlaceholder: !voice.hasText)
                        .frame(height: 136)
                    if lab.reviewDeliveryFailed {
                        Text("The Mac didn’t acknowledge delivery.").font(.caption)
                    } else if let error = voice.dictationIssue {
                        Text(error).font(.caption)
                    }
                    if ready && lab.session.acceptsControls {
                        HStack {
                            Spacer()
                            if !lab.reviewDeliveryFailed { Button("Resume", action: lab.resumeReview) }
                            Button(lab.reviewDeliveryFailed ? "Retry" : "Send", action: lab.sendReview)
                                .buttonStyle(.borderedProminent)
                                .disabled(!voice.canSend)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 520)
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20))
            }
            VStack(spacing: 0) {
                VoiceDraftCancelButton(isVisible: active && !voice.isSubmitting) {
                    if voice.targetID == LabModel.reviewID { lab.stopVoice() }
                }
                VoiceInputButton(voice: voice, id: LabModel.reviewID,
                                 label: active && !ready ? "Review dictation" : "Start dictation") {
                    if !active { lab.startReview() }
                    else if ready {
                        if !lab.reviewDeliveryFailed { lab.resumeReview() }
                    } else { lab.pauseForReview() }
                }
                .disabled(!lab.session.acceptsControls || lab.reviewDeliveryFailed)
                .accessibilityHint("Tap to record. Tap again to review before sending.")
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
        .padding(20)
    }
}

struct FixtureBugReport: View {
    @Environment(LabModel.self) private var lab
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.dismiss) private var dismiss
    @State private var summary = ""
    @State private var reviewing = false
    @State private var filed = false
    private let id = "bug-report-fixture"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Report a bug").font(.title2.weight(.semibold))
            Text("Fixture report. The lab keeps this report in memory.").foregroundStyle(.secondary)
            if filed {
                Label("Fixture report complete", systemImage: "checkmark.circle")
            } else if reviewing {
                Text("Public report preview").font(.headline)
                Text(summary).textSelection(.enabled)
            } else {
                Text("Summary").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Speak naturally. What happened, and what did you expect?",
                          text: $summary, axis: .vertical)
                    .lineLimit(3...6)
                if voice.targetID == id && voice.hasText {
                    Text(voice.transcript).foregroundStyle(.secondary)
                }
                HStack {
                    Text(voice.targetID == id ? voice.statusText : "Speak or type your report").font(.callout)
                    Spacer()
                    VoiceInputButton(voice: voice, id: id, label: "Dictate or pause bug report") {
                        if voice.targetID == id && voice.captureState == .listening { voice.pause() }
                        else if voice.targetID == id { voice.resume() }
                        else { beginVoice() }
                    }
                }
            }
            HStack {
                Button(filed ? "Done" : "Cancel") { dismiss() }
                Spacer()
                if reviewing && !filed {
                    Button("Edit") { reviewing = false }
                    Button("Create Fixture Issue") {
                        lab.lastAction = "Completed fixture bug report"
                        filed = true
                    }
                    .buttonStyle(.borderedProminent)
                } else if !filed {
                    Button("Review Public Report") {
                        if voice.targetID == id && voice.hasText {
                            summary = voice.transcript
                        }
                        voice.closeInput(id)
                        reviewing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(voice.targetID == id && voice.hasText))
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { beginVoice() }
        .onDisappear { voice.closeInput(id) }
    }

    private func beginVoice() {
        voice.activateDraft(id, text: summary) { text in summary = text }
    }
}
