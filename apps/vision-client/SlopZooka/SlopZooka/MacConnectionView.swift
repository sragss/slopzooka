import SwiftUI

/// Shared by first-run connection setup and Settings; owns only form state.
struct MacConnectionView: View {
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var client: CompanionClient
    @State private var showManualAddress = false
    @State private var connectionHost = ""
    @FocusState private var pairingCodeFocused: Bool

    private var selectedMacName: String {
        client.companions.first(where: { $0.candidateHosts.contains(client.normalizedHost) })?.name
            ?? client.current.flatMap { try? client.endpoint(for: $0.id).host() } ?? "your Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if client.needsPairing {
                Text("Connect to \(selectedMacName)").font(.title3.weight(.semibold))
                Text("Enter the six-digit code displayed on your Mac.")
                    .foregroundStyle(.secondary)
                TextField("6-digit code", text: $client.pairingCode)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($pairingCodeFocused)
                    .disabled(client.isPairing)
                    .onChange(of: client.pairingCode) { _, value in
                        let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if value != digits { client.pairingCode = digits; return }
                        if digits.count == 6 { Task { await client.pair() } }
                    }
                    .task(id: client.normalizedHost) {
                        await Task.yield()
                        pairingCodeFocused = true
                        await client.showConnectionCode()
                    }
                    .onChange(of: client.isPairing) { _, pairing in
                        if !pairing { pairingCodeFocused = true }
                    }
                if client.isPairing { ProgressView("Connecting…") }
                if let error = client.pairingError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("You can also find the code in the Mac’s SlopZooka menu.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if client.isReady {
                Label(selectedMacName, systemImage: "desktopcomputer").font(.title3.weight(.semibold))
                Text("Connected").foregroundStyle(.secondary)
            } else {
                Text("Find your Mac").font(.title3.weight(.semibold))
                Text("Open SlopZooka on your Mac and use the same Wi-Fi network.")
                    .foregroundStyle(.secondary)
                if let message = client.healthState.connectionError {
                    Text(client.healthState.isReconnecting ? "Reconnecting to your Mac…" : "Couldn’t reach your Mac.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                    Button("Try Again") { Task { await client.connect() } }
                } else if let message = client.discoveryError {
                    Text("Mac discovery is unavailable.").foregroundStyle(.orange)
                    DisclosureGroup("Details") { Text(message).font(.caption).textSelection(.enabled) }
                } else {
                    ProgressView("Looking for your Mac…")
                }
            }
            if client.companions.count > 1 {
                Menu("Choose another Mac") {
                    ForEach(client.companions) { companion in
                        Button(companion.name) { selectMac(companion.host) }
                    }
                }.disabled(client.isPairing || state.isMutatingWorkspace)
            }
            Button(showManualAddress ? "Hide manual address" : "Enter address manually") {
                showManualAddress.toggle()
            }.font(.subheadline)
            if showManualAddress {
                HStack {
                    TextField("MacName.local:7777", text: $connectionHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find Mac") { selectMac(connectionHost) }
                        .disabled(client.isPairing || state.isMutatingWorkspace || connectionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { connectionHost = client.host }
        .onChange(of: client.host) { old, new in
            if connectionHost.isEmpty || connectionHost == old { connectionHost = new }
        }
    }

    private func selectMac(_ host: String) {
        connectionHost = host
        Task { await client.select(host) }
    }
}
