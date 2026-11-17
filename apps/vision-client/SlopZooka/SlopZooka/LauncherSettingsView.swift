import SwiftUI

struct LauncherSettingsView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left
    @AppStorage(TerminalZoom.defaultStepsKey) private var defaultTerminalZoomSteps = TerminalZoom.initialDefaultSteps

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default terminal zoom", selection: $defaultTerminalZoomSteps) {
                        ForEach(TerminalZoom.stepRange, id: \.self) { steps in
                            Text("\(TerminalZoom.percent(steps: steps))%").tag(steps)
                        }
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Saved across launches. Terminals without a custom zoom use this value. Reset Zoom applies it to any terminal.")
                }
                Section {
                    Text("Hold to talk · Release to send")
                    if voice.targetID != nil {
                        Button("Stop Voice Input", role: .destructive) { voice.stop() }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Pinch and hold the terminal microphone while speaking, then release. A two-second countdown gives you time to cancel with × before sending. Works in either workspace mode.")
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
                        LabeledContent("Connected Mac", value: client.isReady ? "Connected" : "Not connected")
                    }
                    DisclosureGroup("Troubleshooting") {
                        Button("Reload All Window Content", systemImage: "arrow.clockwise") { windows.reload() }
                            .disabled(!client.isReady)
                        Text("Reloads content without ending sessions or moving windows.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if case .success = client.healthState, let health = client.health {
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
