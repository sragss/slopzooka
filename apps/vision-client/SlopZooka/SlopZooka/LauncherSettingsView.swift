import SwiftUI

struct LauncherSettingsView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Persistent voice input", isOn: $voice.conversationEnabled)
                    if voice.targetID != nil {
                        Button("Stop Voice Input", role: .destructive) { voice.stop() }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Pinch the microphone orb at a terminal’s bottom right to start. Pauses keep your draft; tap Send to submit and keep listening. Works in either workspace mode. Off restores one-shot dictation.")
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
                        ProgressView("Updating workspace…")
                    }
                    if let error = workspace.error {
                        Text(error).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Adds wrist controls while keeping your room visible. Other apps are hidden until you turn this off.")
                }
                Section {
                    NavigationLink {
                        ScrollView { MacConnectionView().padding(24) }
                            .navigationTitle("Your Mac")
                    } label: {
                        LabeledContent("Connected Mac", value: state.isReady ? "Connected" : "Not connected")
                    }
                    DisclosureGroup("Troubleshooting") {
                        Button("Reload All Window Content", systemImage: "arrow.clockwise") { windows.reload() }
                            .disabled(!state.isReady)
                        Text("Reloads content without ending sessions or moving windows.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if case .success(let health) = state.healthState {
                            Text("Address: \(health.controlOrigin)").textSelection(.enabled)
                            Text("Logs: \(health.logFilePath)").textSelection(.enabled)
                        }
                        if let error = windows.persistenceError { Text(error).foregroundStyle(.orange) }
                    }
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
