import SwiftUI

/// Shared by first-run connection setup and Settings; owns only form state.
struct MacConnectionView: View {
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var discovery: CompanionDiscovery
    @State private var showManualAddress = false
    @State private var connectionHost = ""
    @FocusState private var pairingCodeFocused: Bool

    private var selectedMacName: String {
        discovery.companions.first(where: { $0.candidateHosts.contains(state.normalizedHost) })?.name
            ?? state.connection.endpoint?.host() ?? "your Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if state.needsPairing {
                Text("Connect to \(selectedMacName)").font(.title3.weight(.semibold))
                Text("Enter the six-digit code displayed on your Mac.")
                    .foregroundStyle(.secondary)
                TextField("6-digit code", text: $state.pairingCode)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($pairingCodeFocused)
                    .disabled(state.isPairing)
                    .onChange(of: state.pairingCode) { _, value in
                        let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if value != digits { state.pairingCode = digits; return }
                        if digits.count == 6 { Task { await state.pair() } }
                    }
                    .task(id: state.normalizedHost) {
                        await Task.yield()
                        pairingCodeFocused = true
                        await state.showConnectionCode()
                    }
                    .onChange(of: state.isPairing) { _, pairing in
                        if !pairing { pairingCodeFocused = true }
                    }
                if state.isPairing { ProgressView("Connecting…") }
                if let error = state.pairingError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("You can also find it in the Mac’s bazooka menu → Show Connection Code.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.isReady {
                Label(selectedMacName, systemImage: "desktopcomputer").font(.title3.weight(.semibold))
                Text("Connected").foregroundStyle(.secondary)
            } else {
                Text("Find your Mac").font(.title3.weight(.semibold))
                Text("Open SlopZooka on your Mac and use the same Wi-Fi network.")
                    .foregroundStyle(.secondary)
                if case .failure(let message) = state.healthState {
                    Text("Couldn’t reach your Mac.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                    Button("Try Again") { Task { await state.connectAndRefresh() } }
                } else if case .failed(let message) = discovery.state {
                    Text("Mac discovery is unavailable.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                } else {
                    ProgressView("Looking for your Mac…")
                }
            }
            if discovery.companions.count > 1 {
                Menu("Choose another Mac") {
                    ForEach(discovery.companions) { companion in
                        Button(companion.name) { selectMac(companion.host) }
                    }
                }.disabled(state.isPairing || state.isMutatingWorkspace)
            }
            Button(showManualAddress ? "Hide manual address" : "Enter address manually") {
                showManualAddress.toggle()
            }.font(.subheadline)
            if showManualAddress {
                HStack {
                    TextField("MacName.local:7777", text: $connectionHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find Mac") { selectMac(connectionHost) }
                        .disabled(state.isPairing || state.isMutatingWorkspace || connectionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { connectionHost = state.host }
        .onChange(of: state.host) { old, new in
            if connectionHost.isEmpty || connectionHost == old { connectionHost = new }
        }
    }

    private func selectMac(_ host: String) {
        connectionHost = host
        state.host = host
        state.pairingCode = ""
        state.pairingError = nil
        Task { await state.connectAndRefresh() }
    }
}
