import SwiftUI

private let voiceAccent = Color("AccentHighlight")

struct TerminalVoiceButton: View {
    let id: String
    let isAvailable: Bool
    @EnvironmentObject private var voice: TerminalVoiceController

    var body: some View {
        VoiceInputButton(voice: voice, id: id, label: "Hold to dictate", onPressingChanged: { pressing in
            if pressing { voice.beginTerminalHold(id) }
            else { voice.endTerminalHold(id) }
        }) {}
        .overlay(alignment: .bottom) {
            if voice.targetID != id {
                Text("Hold to talk")
                    .font(.caption2)
                    .offset(y: 14)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHint("Hold while speaking, then release. Tap the close button within three seconds to cancel before sending.")
        .accessibilityAction {
            if voice.targetID == id && voice.mode == .terminal { voice.endTerminalHold(id) }
            else { voice.beginTerminalHold(id) }
        }
        .opacity(isAvailable ? 1 : 0.45)
        .disabled(!isAvailable || voice.isSubmitting || voice.sendDeadline != nil)
    }
}

/// Shared microphone control for terminal input and native composition.
struct VoiceInputButton: View {
    @ObservedObject var voice: TerminalVoiceController
    let id: String
    let label: String
    var onPressingChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VoiceOrb(isSelected: voice.targetID == id,
                isListening: voice.targetID == id && voice.captureState == .listening,
                isBusy: voice.targetID == id && (voice.isSubmitting || voice.captureState == .preparing || voice.captureState == .finishing),
                audioLevels: voice.audioLevels)
                .frame(width: 88, height: 88)
                .glassBackgroundEffect(in: Circle())
                .frame(width: 120, height: 120)
                .contentShape(Circle())
        }
        .buttonStyle(VoicePressStyle(onPressingChanged: onPressingChanged))
        .buttonBorderShape(.circle)
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.lift)
        .accessibilityLabel(label)
        .accessibilityValue(voice.targetID == id ? voice.statusText : "Off")
    }
}

/// Native button tracking recognizes the initial pinch and its release without
/// requiring a drag or a minimum long-press duration.
private struct VoicePressStyle: ButtonStyle {
    let onPressingChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressing in onPressingChanged?(pressing) }
    }
}

/// Foreground content only; visionOS owns the button's glass material and lighting.
/// Listening motion follows microphone energy inside a fixed hit area.
private struct VoiceOrb: View {
    let isSelected: Bool
    let isListening: Bool
    let isBusy: Bool
    let audioLevels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isBusy {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1) * 360
                    Circle().trim(from: 0.12, to: 0.85)
                        .stroke(voiceAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(angle))
                }
            } else if isListening {
                HStack(spacing: 4) {
                    ForEach(audioLevels.indices, id: \.self) { index in
                        Capsule().fill(voiceAccent)
                            .frame(width: 4, height: 6 + 28 * audioLevels[index])
                    }
                }
                .frame(width: 40, height: 40)
                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: audioLevels)
            } else {
                Image(systemName: isSelected ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(isSelected ? voiceAccent : .white)
            }
        }
        .accessibilityHidden(true)
    }
}

/// All voice tasks share a centered glass draft; the microphone stays bottom right.
struct TerminalVoiceOverlay: ViewModifier {
    let id: String
    let isAvailable: Bool
    let canRename: Bool
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var submitSound = TerminalVoiceSubmitSound()
    @State private var submitPulse = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(voiceAccent.opacity(voice.captureState == .listening ? 0.8 : 0.3), lineWidth: 2)
                    .opacity(voice.targetID == id ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: voice.targetID == id)
                    .allowsHitTesting(false)
            }
            .overlay {
                // Keep the glass surface mounted at its centered geometry. Only
                // opacity changes; closing never presents/dismisses glass from
                // the microphone's interaction origin.
                TerminalVoiceDraft(id: id)
                    .transaction { $0.animation = nil }
                    .frame(maxWidth: 520)
                    .padding(20)
                    .opacity(voice.targetID == id ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: voice.targetID == id)
                    .allowsHitTesting(voice.targetID == id)
                    .accessibilityHidden(voice.targetID != id)
            }
            .overlay(alignment: .bottomTrailing) {
                TerminalVoiceButton(id: id, isAvailable: isAvailable)
                    .fixedSize()
                    .padding(20)
            }
            .onChange(of: voice.mode == .rename ? canRename : isAvailable) { _, available in
                if !available { voice.targetUnavailable(id) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(voiceAccent, lineWidth: 4)
                    .opacity(submitPulse ? 0.8 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: submitPulse ? 0.1 : 0.28), value: submitPulse)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: voice.lastSubmission) { _, command in
                guard command?.targetID == id else { return }
                submitSound.play()
                submitPulse = true
            }
            .task(id: submitPulse) {
                guard submitPulse else { return }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                submitPulse = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { voice.targetUnavailable(id) }
            }
            .onDisappear { voice.targetUnavailable(id) }
    }
}

private struct TerminalVoiceDraft: View {
    let id: String
    @EnvironmentObject private var voice: TerminalVoiceController
    @State private var retainedTranscript = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.mode == .rename {
                Text("Name this \(voice.renameTarget.rawValue)").font(.title2.weight(.semibold))
            }
            HStack {
                Image(systemName: voice.captureState == .listening ? "mic.fill" : "mic.slash")
                    .foregroundStyle(voice.captureState == .listening ? voiceAccent : .secondary)
                    .accessibilityHidden(true)
                if voice.targetID == id, let deadline = voice.sendDeadline {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text("Sending in \(max(1, Int(ceil(deadline.timeIntervalSince(context.date)))))s")
                            .font(.caption)
                    }
                } else {
                    Text(voice.statusText).font(.caption)
                }
                Spacer(minLength: 0)
                Button("Cancel", systemImage: "xmark") { voice.stop() }
                    .labelStyle(.iconOnly)
                    .disabled(voice.isSubmitting)
                    .accessibilityLabel("Cancel voice input and discard draft")
            }
            ScrollView {
                Text(hasVisibleText ? visibleTranscript : placeholder)
                    .foregroundStyle(hasVisibleText ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: voice.mode == .rename || voice.mode == .draft ? 148 : 80)
            if voice.mode != nil && (voice.mode != .terminal || (voice.hasText && voice.sendDeadline == nil
                && voice.captureState != .listening && voice.captureState != .finishing && !voice.isSubmitting)) {
                HStack {
                    Spacer()
                    if voice.canResume && voice.mode != .terminal {
                        Button("Resume") { voice.resume() }
                    }
                    Button(voice.mode == .rename ? "Save Name" : (voice.needsRetry ? "Retry" : "Send")) { voice.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!voice.canSend)
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: voice.transcript) { _, _ in
            if voice.targetID == id { retainedTranscript = draft }
        }
        .task(id: voice.targetID == id) {
            guard voice.targetID != id else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            retainedTranscript = ""
        }
        .padding(16)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            if voice.targetID == id, let deadline = voice.sendDeadline {
                TimelineView(.animation) { context in
                    let progress = min(1, max(0, 1 - deadline.timeIntervalSince(context.date) / TerminalVoiceController.sendDelay))
                    RoundedRectangle(cornerRadius: 20)
                        .trim(from: 0, to: progress)
                        .stroke(voiceAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    // stop() clears voice state immediately. Keep the last words and terminal
    // card height steady while the now-inert surface fades out.
    private var visibleTranscript: String { voice.targetID == id ? draft : retainedTranscript }
    private var hasVisibleText: Bool { !visibleTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if voice.mode == .rename { return "Say a name. A short pause saves it with dashes between words." }
        return "Speak naturally."
    }

    private var draft: String {
        voice.mode == .rename ? WindowName.normalized(voice.transcript) : voice.transcript
    }
}
