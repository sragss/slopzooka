import SwiftUI

struct LauncherSettingsView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ImmersiveWorkspaceControl()
                    if workspace.isEnabled {
                        Picker("Wrist", selection: $workspace.wrist) {
                            ForEach(ImmersiveWorkspaceState.Wrist.allCases) { wrist in
                                Text(wrist.title).tag(wrist)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(workspace.isTransitioning)
                    }
                    if workspace.isTransitioning {
                        ProgressView(workspace.phase == .opening ? "Opening workspace…" : "Closing workspace…")
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
                    NavigationLink("Troubleshooting") { troubleshooting }
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

    private var troubleshooting: some View {
        Form {
            Section {
                Button("Reload All Window Content", systemImage: "arrow.clockwise") { windows.reload() }
                    .disabled(!state.isReady)
            } footer: {
                Text("Reloads terminal and preview content without ending sessions or moving windows.")
            }
            if case .success(let health) = state.healthState {
                Section("Mac details") {
                    Text("Address: \(health.controlOrigin)")
                    Text("Logs: \(health.logFilePath)")
                }.textSelection(.enabled)
            }
            if let error = windows.persistenceError {
                Section("Window recovery") { Text(error).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Troubleshooting")
    }
}
