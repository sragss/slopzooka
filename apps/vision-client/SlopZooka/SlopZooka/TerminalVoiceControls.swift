import SwiftUI

private let voiceAccent = Color(red: 0.63, green: 0.94, blue: 0.85)

struct TerminalVoiceButton: View {
    let id: String
    let isAvailable: Bool
    @EnvironmentObject private var voice: TerminalVoiceController

    var body: some View {
        Button { voice.activateTerminal(id) } label: {
            VoiceOrb(isSelected: voice.targetID == id,
                isListening: voice.targetID == id && voice.captureState == .listening,
                isBusy: voice.targetID == id && (voice.isSubmitting || voice.captureState == .preparing || voice.captureState == .finishing),
                audioLevels: voice.audioLevels)
                .frame(width: 88, height: 88)
                .frame(width: 112, height: 112)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.lift)
        .accessibilityLabel(voice.targetID == id ? "Stop voice input" : "Dictate to terminal")
        .accessibilityValue(voice.targetID == id ? voice.statusText : "Off")
        .help(voice.targetID == id ? "Stop voice input" : "Dictate to terminal")
        .opacity(isAvailable ? 1 : 0.45)
        .disabled(!isAvailable || voice.isSubmitting)
    }
}

/// Solid navy and the app icon's mint accent. Listening motion comes only from
/// microphone energy; the fixed hit area never moves with the waveform.
private struct VoiceOrb: View {
    let isSelected: Bool
    let isListening: Bool
    let isBusy: Bool
    let audioLevels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.06, green: 0.09, blue: 0.17))
            if isBusy {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1) * 360
                    Circle().trim(from: 0.12, to: 0.85)
                        .stroke(voiceAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(angle))
                }
            } else if isListening {
                HStack(spacing: 3) {
                    ForEach(audioLevels.indices, id: \.self) { index in
                        Capsule().fill(voiceAccent)
                            .frame(width: 4, height: 6 + 28 * audioLevels[index])
                    }
                }
                .frame(width: 36, height: 36)
                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: audioLevels)
            } else {
                Image(systemName: isSelected ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(voiceAccent)
            }
        }
        .overlay {
            Circle().strokeBorder(isSelected ? voiceAccent : .white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

/// Shared UI for the original one-shot flow and the compact conversation dock.
struct TerminalVoiceOverlay: ViewModifier {
    let id: String
    let isAvailable: Bool
    var onSent: () -> Void
    @EnvironmentObject private var voice: TerminalVoiceController

    func body(content: Content) -> some View {
        content
            .overlay {
                if voice.targetID == id {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(voiceAccent.opacity(voice.captureState == .listening ? 0.8 : 0.3), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if voice.targetID == id && (voice.mode == .dictation || voice.mode == .rename) {
                    TerminalVoiceDraft()
                        .frame(maxWidth: 520)
                        .padding(20)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(alignment: .bottom, spacing: 16) {
                    if voice.targetID == id && voice.mode == .conversation {
                        TerminalVoiceDraft().frame(maxWidth: 520)
                    }
                    TerminalVoiceButton(id: id, isAvailable: isAvailable).fixedSize()
                }
                .padding(20)
            }
            .onChange(of: isAvailable) { _, available in
                if !available { voice.targetUnavailable(id) }
            }
            .onChange(of: voice.lastAcknowledgedCommand) { _, command in
                if isAvailable && command?.targetID == id { onSent() }
            }
            .onDisappear { voice.targetUnavailable(id) }
    }
}

private struct TerminalVoiceDraft: View {
    @EnvironmentObject private var voice: TerminalVoiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.mode == .rename {
                Text("Name this window").font(.title2.weight(.semibold))
            }
            HStack {
                Image(systemName: voice.captureState == .listening ? "mic.fill" : "mic.slash")
                    .foregroundStyle(voice.captureState == .listening ? voiceAccent : .secondary)
                Text(voice.statusText).font(.caption)
                Spacer(minLength: 0)
                Button("Stop", systemImage: "xmark") { voice.stop() }
                    .labelStyle(.iconOnly)
                    .disabled(voice.isSubmitting)
                    .accessibilityLabel("Stop voice input and discard draft")
            }
            ScrollView {
                Text(voice.hasText ? draft : placeholder)
                    .foregroundStyle(voice.hasText ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: voice.mode == .conversation ? 80 : 148)
            HStack {
                Button("Discard") { voice.discard() }
                    .disabled(voice.isSubmitting)
                Spacer()
                if voice.canResume {
                    Button("Resume") { voice.resume() }
                }
                Button(voice.mode == .rename ? "Save Name" : (voice.needsRetry ? "Retry" : "Send")) { voice.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!voice.canSend)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var placeholder: String {
        if voice.mode == .rename { return "Say a name. A short pause saves it with dashes between words." }
        return voice.mode == .dictation ? "Speak naturally. A short pause sends your message."
            : "Speak naturally. Pauses keep your draft; tap Send when ready."
    }

    private var draft: String {
        voice.mode == .rename ? WindowName.normalized(voice.transcript) : voice.transcript
    }
}
