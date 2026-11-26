import SwiftUI

struct LauncherSettingsView: View {
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left
    @AppStorage(TerminalZoom.defaultStepsKey) private var defaultTerminalZoomSteps = TerminalZoom.initialDefaultSteps
    @AppStorage(TerminalKeyboard.optionAsMetaKey) private var optionAsMeta = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default terminal zoom", selection: $defaultTerminalZoomSteps) {
                        ForEach(TerminalZoom.stepRange, id: \.self) { steps in
                            Text("\(TerminalZoom.percent(steps: steps))%").tag(steps)
                        }
                    }
                    Toggle("Use Option as Meta", isOn: $optionAsMeta)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Reset Zoom applies the saved default. Use Option as Meta for shortcuts like Option+B in Codex and Claude Code.")
                }
                Section {
                    Text("Hold to talk · Release to send")
                    if voice.targetID != nil {
                        Button("Stop Voice Input", role: .destructive) { voice.stop() }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Pinch and hold the terminal microphone while speaking, then release. A two-second countdown gives you time to cancel with × before sending. Works in both windowed and immersive modes.")
                }
                Section {
                    ImmersiveWorkspaceControl()
                    if workspace.isPresented {
                        Picker("Wrist", selection: $wrist) {
                            ForEach(Wrist.allCases, id: \.self) { wrist in
                                Text(wrist.rawValue.capitalized).tag(wrist)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(workspace.isTransitioning)
                    }
                    if workspace.isTransitioning {
                        ProgressView("Updating immersive mode…")
                    }
                    if let error = workspace.error {
                        Text(error).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Presentation")
                } footer: {
                    Text("Adds wrist controls while keeping your room visible. Other apps are hidden until you turn this off.")
                }
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

}
