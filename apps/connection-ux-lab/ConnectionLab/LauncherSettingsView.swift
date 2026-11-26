import SwiftUI

struct LauncherSettingsView: View {
    private enum Wrist: String, CaseIterable { case left, right }

    @Environment(LabModel.self) private var lab
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left
    @AppStorage("defaultTerminalZoomSteps") private var defaultTerminalZoomSteps = -2
    @AppStorage("terminalOptionAsMeta") private var optionAsMeta = false

    var body: some View {
        NavigationStack {
            Form {
                terminal
                voice
                presentation
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 540, height: 560)
    }

    private var terminal: some View {
        Section {
            Picker("Default terminal zoom", selection: $defaultTerminalZoomSteps) {
                ForEach(-9...10, id: \.self) { steps in
                    Text("\(100 + steps * 10)%").tag(steps)
                }
            }
            Toggle("Use Option as Meta", isOn: $optionAsMeta)
        } header: {
            Text("Terminal")
        } footer: {
            Text("Reset Zoom applies the saved default. Use Option as Meta for shortcuts like Option+B in Codex and Claude Code.")
        }
    }

    private var voice: some View {
        Section {
            Text("Hold to talk · Release to send")
            if lab.voiceActive {
                Button("Stop Voice Input", role: .destructive) { lab.voiceActive = false }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Pinch and hold the terminal microphone while speaking, then release. A two-second countdown gives you time to cancel with × before sending. Works in both windowed and immersive modes.")
        }
    }

    private var presentation: some View {
        Section {
            Toggle("Immersive mode", isOn: Binding(get: { lab.immersive }, set: { lab.setImmersive($0) }))
                .disabled(lab.immersiveTarget != nil)
            if lab.immersive {
                Picker("Wrist", selection: $wrist) {
                    ForEach(Wrist.allCases, id: \.self) { wrist in
                        Text(wrist.rawValue.capitalized).tag(wrist)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(lab.immersiveTarget != nil)
            }
            if lab.immersiveTarget != nil {
                ProgressView("Updating immersive mode…")
            }
            if let error = lab.immersiveError {
                Text(error).foregroundStyle(.orange)
            }
        } header: {
            Text("Presentation")
        } footer: {
            Text("Adds wrist controls while keeping your room visible. Other apps are hidden until you turn this off.")
        }
    }

}
