import SwiftUI

struct ScenarioControls: View {
    @Environment(LabModel.self) private var lab

    var body: some View {
        @Bindable var lab = lab
        NavigationStack {
            Form {
                Section {
                    Menu {
                        ForEach(LabScenario.Group.allCases, id: \.self) { group in
                            Menu(group.rawValue) {
                                ForEach(LabScenario.allCases.filter { $0.group == group }) { scenario in
                                    Button(scenario.rawValue) { lab.load(scenario) }
                                }
                            }
                        }
                    } label: {
                        LabeledContent("Scenario", value: lab.scenario.rawValue)
                    }
                    Button("Reset Scenario", systemImage: "arrow.counterclockwise") { lab.load(lab.scenario) }
                    Menu("Show Screen", systemImage: "rectangle") {
                        Button("Launcher") { lab.navigate(.launcher) }
                        Button("Settings") { lab.navigate(.settings) }
                        Button("Your Mac") { lab.navigate(.yourMac) }
                        Button("Frontends") { lab.navigate(.frontends) }
                        Button("Ask SlopZooka") { lab.navigate(.ask) }
                    }
                } footer: {
                    Text("Move this window aside to review the launcher. Complete any requests that are waiting here.")
                }

                Section("Pending requests") {
                    if let label = lab.pendingLabel {
                        Button(label, action: lab.advanceConnection)
                    }
                    if lab.immersiveTarget != nil {
                        Button("Complete immersive transition", action: lab.advanceImmersive)
                    }
                    if lab.isRequestingVoice {
                        Button("Complete permission request", action: lab.advanceVoice)
                    }
                    if lab.pendingLabel == nil && lab.immersiveTarget == nil && !lab.isRequestingVoice {
                        Text("No pending requests").foregroundStyle(.secondary)
                    }
                }

                Section("Mac") {
                    Toggle("Auto-connect fixture Macs", isOn: $lab.autoConnectFixture)
                    outcomePicker("Bonjour discovery result", selection: $lab.discoveryOutcome)
                    outcomePicker("Local Network response", selection: fault(for: .localNetwork))
                    outcomePicker("Direct response", selection: fault(for: .direct))
                    outcomePicker("Pairing response", selection: $lab.pairingOutcome)
                    LabeledContent("Pairing code", value: LabModel.validCode)
                    LabeledContent("Mac code window", value: lab.isCodeDisplayed ? "Visible" : "Hidden")
                    if lab.needsPairing {
                        Button(lab.isCodeDisplayed ? "Dismiss Mac Code Window" : "Show Mac Code Window") {
                            if lab.isCodeDisplayed { lab.dismissCode() } else { lab.showCode() }
                        }
                    }
                    DisclosureGroup("Sample addresses") {
                        ForEach(LabMac.allCases) { mac in
                            Text(mac.address).textSelection(.enabled)
                            Text(mac.manualIP).textSelection(.enabled)
                        }
                    }
                    Button("Restart Bonjour Discovery", action: lab.restartDiscovery)
                        .disabled(lab.method != .localNetwork || lab.isReady || lab.needsPairing)
                    Button("Simulate Connection Loss", action: lab.loseConnection).disabled(!lab.isReady)
                    Button("Revoke Pairing", action: lab.revokePairing).disabled(!lab.isReady)
                    Button("Simulate Relaunch", action: lab.relaunch)
                    Toggle("Workspace mutation in progress", isOn: $lab.workspaceBusy)
                }

                Section("Settings and permissions") {
                    outcomePicker("Immersive result", selection: $lab.immersiveOutcome)
                    Toggle("Voice input active", isOn: $lab.voiceActive)
                    outcomePicker("Next voice permission", selection: $lab.nextVoicePermission)
                    outcomePicker("Mac Screen Recording", selection: $lab.capture)
                    if let action = lab.captureAction { LabeledContent("Last Mac permission action", value: action) }
                    LabeledContent("Window reload requests", value: String(lab.reloadCount))
                }
            }
            .navigationTitle("Connection Lab Controls")
        }
    }

    private func fault(for method: ConnectionMethod) -> Binding<ConnectionFault> {
        Binding(get: { lab.faults[method] ?? .healthy }, set: { lab.faults[method] = $0 })
    }

    private func outcomePicker<Value: CaseIterable & RawRepresentable & Identifiable & Hashable>(
        _ title: String, selection: Binding<Value>
    ) -> some View where Value.RawValue == String {
        Picker(title, selection: selection) {
            ForEach(Array(Value.allCases)) { value in Text(value.rawValue).tag(value) }
        }
    }
}
