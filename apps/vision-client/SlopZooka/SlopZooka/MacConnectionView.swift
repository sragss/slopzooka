import SwiftUI

private enum ConnectionPage: Hashable { case chooseMac, options }

struct MacConnectionFlow: View {
    let isSetup: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            page(picker: false)
                .navigationTitle(isSetup ? "" : "Connection")
                .toolbar {
                    if !isSetup {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
                }
                .navigationDestination(for: ConnectionPage.self) { page in
                    switch page {
                    case .chooseMac: self.page(picker: true).navigationTitle("Choose Another Mac")
                    case .options: ConnectionOptionsPage()
                    }
                }
        }
    }

    private func page(picker: Bool) -> some View {
        ScrollView {
            MacConnectionView(isSetup: isSetup, isPicker: picker)
                .padding(isSetup ? 32 : 24)
        }
        .scrollIndicators(.hidden)
    }
}

private struct MacConnectionView: View {
    let isSetup: Bool
    let isPicker: Bool
    @EnvironmentObject private var state: LauncherState
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var windows: WindowGateway
    @State private var showManualAddress = false
    @State private var address = ""
    @FocusState private var pairingCodeFocused: Bool

    private var showsPicker: Bool { isSetup || isPicker }
    private var canSelect: Bool { !client.isPairing && !client.isChecking && !state.isMutatingWorkspace }
    private var canFindMac: Bool { canSelect && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !isPicker || client.needsPairing {
                Text(client.needsPairing ? "Pair with \(client.macName)" : (isSetup ? "Connect to a Mac" : client.macName))
                    .font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
            connectionState
            if showsPicker && client.connectionMethod == .localNetwork && !client.companions.isEmpty {
                nearbyMacs
            }
            actions
            if !showsPicker { connectionDetails }
        }
        .onAppear { address = client.host }
        .onChange(of: client.host) { old, new in
            if address.isEmpty || address == old { address = new }
        }
    }

    @ViewBuilder
    private var connectionState: some View {
        if client.needsPairing && !client.isChecking {
            pairing
        } else if client.isChecking || client.isActivelyReconnecting {
            status(client.isActivelyReconnecting ? "Reconnecting…" : "Connecting…",
                   detail: client.connectionMethod == .localNetwork ? client.normalizedHost : nil,
                   icon: "desktopcomputer", active: client.isActivelyReconnecting) {
                if client.isChecking { cancelButton }
            }
        } else if client.isReady && !isPicker {
            status("Connected", detail: client.connectionMethod.title, icon: "checkmark", color: .green) {}
        } else if let message = client.healthState.connectionError {
            status(isSetup ? "Couldn’t reach your Mac" : "Connection interrupted", detail: nil,
                   icon: "exclamationmark", color: .orange) {
                if !client.normalizedHost.isEmpty {
                    Button {
                        Task { await client.connect() }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("Try Again").disabled(!canSelect)
                }
            }
            if client.connectionMethod == .direct && !isPicker {
                Button("Use Local Network") { Task { await client.setConnectionMethod(.localNetwork) } }
                    .buttonStyle(.bordered).disabled(!canSelect)
            }
            errorDetails(message)
        }
        if showsPicker && client.connectionMethod == .localNetwork && !client.isChecking && !client.needsPairing {
            if let message = client.discoveryError {
                status("Discovery unavailable", detail: "You can still enter your Mac’s address.",
                       icon: "exclamationmark", color: .orange) {}
                errorDetails(message)
                Button("Search Again") { client.retryDiscovery() }.buttonStyle(.bordered)
            } else if client.companions.isEmpty {
                status("Searching nearby…", detail: "Open SlopZooka on your Mac.", icon: "desktopcomputer") {}
            }
        }
        if isPicker && client.connectionMethod == .direct {
            Button("Use Local Network to Find Macs") { Task { await client.setConnectionMethod(.localNetwork) } }
                .buttonStyle(.bordered).disabled(!canSelect)
        }
    }

    private func status<Action: View>(_ label: String, detail: String?, icon: String, color: Color = .cyan,
                                      active: Bool = false, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 21, weight: .medium))
                    .foregroundStyle(color).frame(width: 52, height: 52)
                    .background(color.opacity(0.13), in: Circle())
                    .overlay { if active { ConnectionActivityRing().padding(-3) } }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).font(.title3.weight(.semibold))
                    if let detail, !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            action()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
    }

    private var cancelButton: some View {
        Button("Cancel") { Task { await client.cancelConnection() } }
            .buttonStyle(.bordered).fixedSize(horizontal: true, vertical: false)
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            if client.isPairing {
                HStack {
                    Text("Checking code…").font(.headline)
                    Spacer()
                    cancelButton
                }
            } else {
                Text("Enter the six-digit code shown on your Mac.").font(.headline)
            }
            TextField("6-digit code", text: $client.pairingCode)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($pairingCodeFocused).disabled(client.isPairing)
                .onChange(of: client.pairingCode) { _, value in
                    let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    if value != digits { client.pairingCode = digits; return }
                    if digits.count == 6 { Task { await client.pair() } }
                }
                .task(id: client.current) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    pairingCodeFocused = !client.isPairing
                    await client.showConnectionCode()
                }
                .onChange(of: client.isPairing) { _, pairing in
                    if !pairing && client.needsPairing { pairingCodeFocused = true }
                }
            if let message = client.pairingError {
                Text(message).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
    }

    private var nearbyMacs: some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Macs").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(client.companions) { mac in
                let selected = (client.isReady || client.needsPairing) && mac.candidateHosts.contains(client.normalizedHost)
                Button {
                    Task { await client.select(mac) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").frame(width: 36, height: 36)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mac.name).lineLimit(1)
                            if client.companions.contains(where: { $0.id != mac.id && $0.name == mac.name }) {
                                Text(mac.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 60)
                    .background(.white.opacity(0.05), in: shape)
                    .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
                    .contentShape([.interaction, .hoverEffect], shape).hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .disabled(!canSelect || selected)
            }
        }
    }

    private var actions: some View {
        let manual = showsPicker && client.connectionMethod == .localNetwork
        return VStack(alignment: .leading, spacing: 0) {
            if manual {
                Button { showManualAddress.toggle() } label: {
                    actionLabel("Enter address manually", icon: showManualAddress ? "chevron.down" : "chevron.right", top: 16)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showManualAddress ? "Expanded" : "Collapsed")
                if showManualAddress {
                    HStack {
                        TextField("MacName.local:7777", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { if canFindMac { selectAddress() } }
                        Button("Find Mac", action: selectAddress).disabled(!canFindMac)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                Divider()
            }
            if !showsPicker {
                NavigationLink(value: ConnectionPage.chooseMac) {
                    actionLabel("Choose Another Mac", icon: "chevron.right", top: 16)
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)
                Divider()
            }
            NavigationLink(value: ConnectionPage.options) {
                actionLabel("Connection options", icon: "chevron.right", top: manual || !showsPicker ? 0 : 16, bottom: 16)
            }
            .buttonStyle(.plain)
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let health = client.health {
                detailRow("Address", value: health.controlOrigin)
                Divider()
                detailRow("Logs", value: health.logFilePath)
                Divider()
            }
            if let error = windows.persistenceError {
                Text(error).font(.footnote).foregroundStyle(.orange).padding(16)
                Divider()
            }
            Button { windows.reload() } label: {
                actionLabel("Reload All Window Content", icon: "arrow.clockwise",
                            top: client.health == nil && windows.persistenceError == nil ? 16 : 0, bottom: 16)
            }
            .buttonStyle(.plain).disabled(!client.isReady)
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        } label: {
            Text(title)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 48)
    }

    private func actionLabel(_ title: String, icon: String, top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top)
        return HStack {
            Text(title)
            Spacer()
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 60)
        .contentShape([.interaction, .hoverEffect], shape).hoverEffect(.highlight)
    }

    private func errorDetails(_ message: String) -> some View {
        DisclosureGroup("Details") {
            Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func selectAddress() {
        let selected = address
        Task { await client.select(selected) }
    }
}

private struct ConnectionOptionsPage: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var state: LauncherState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                methodRow(.localNetwork, icon: "wifi")
                methodRow(.direct, icon: "desktopcomputer")
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Connection options")
    }

    private func methodRow(_ method: ConnectionMethod, icon: String) -> some View {
        let selected = method == client.connectionMethod
        let shape = RoundedRectangle(cornerRadius: 22)
        return Button {
            dismiss()
            Task { await client.setConnectionMethod(method) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(method.title)
                    if method == .direct {
                        Text("Experimental · Uses your saved pairing")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(.white.opacity(selected ? 0.12 : 0.05), in: shape)
            .contentShape([.interaction, .hoverEffect], shape).hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(client.isPairing || client.isChecking || state.isMutatingWorkspace)
    }
}

struct ConnectionActivityRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(.cyan.opacity(0.20), lineWidth: 2)
            if reduceMotion {
                arc
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let turn = elapsed.truncatingRemainder(dividingBy: 1.2) / 1.2
                    arc.rotationEffect(.degrees(turn * 360))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var arc: some View {
        Circle().inset(by: 1).trim(from: 0, to: 0.27)
            .stroke(.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
