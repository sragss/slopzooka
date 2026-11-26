import SwiftUI

struct ConnectionFlowView: View {
    var onDone: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView { ConnectionHomeView().padding(onDone == nil ? 32 : 24) }
                .scrollIndicators(.hidden)
                .navigationTitle(onDone == nil ? "" : "Connection")
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
                }
                .navigationDestination(for: ConnectionPage.self) { page in
                    switch page {
                    case .chooseMac:
                        ScrollView { ConnectionHomeView(isPicker: true).padding(24) }
                            .scrollIndicators(.hidden)
                            .navigationTitle("Choose Another Mac")
                    case .options:
                        ConnectionOptionsPage()
                    }
                }
        }
    }
}

private enum ConnectionPage: Hashable { case chooseMac, options }

private struct ConnectionHomeView: View {
    private enum StatusAction { case cancel, retry }

    var isPicker = false
    @Environment(LabModel.self) private var lab
    @State private var showManualAddress = false
    @State private var address = ""

    private var isSetup: Bool { lab.workspaceMacName == nil }
    private var showsMacPicker: Bool { isSetup || isPicker }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !isPicker || lab.needsPairing {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            mainContent
            if showsMacPicker {
                if lab.method == .localNetwork && !lab.discovered.isEmpty { discoveredMacs }
                if isPicker && lab.method == .direct {
                    Button("Use Local Network to Find Macs") { lab.changeMethod(.localNetwork) }
                        .buttonStyle(.bordered)
                        .disabled(!lab.canChangeConnection)
                }
            }
            connectionOptions
            if !showsMacPicker { connectionDetails }
        }
        .onAppear {
            address = lab.host
            showManualAddress = lab.startsWithManualAddress
        }
        .onChange(of: lab.host) { old, new in
            if address.isEmpty || address == old { address = new }
        }
        .task {
            if isPicker && !lab.isDiscovering && !lab.discovered.contains(where: { $0 != lab.mac }) {
                lab.findMacs()
            }
        }
    }

    private var title: String {
        if lab.needsPairing { return "Pair with \(lab.mac?.rawValue ?? lab.selectedMacName)" }
        if let name = lab.workspaceMacName { return name }
        return "Connect to a Mac"
    }

    @ViewBuilder
    private var mainContent: some View {
        if lab.needsPairing {
            pairing
        } else if lab.isReady && !isPicker {
            status("Connected", detail: lab.method.rawValue, icon: "checkmark", color: .green)
        } else if let message = lab.phase.error {
            connectionFailure(message)
        } else if lab.phase == .checking {
            status("Connecting…", detail: lab.method == .localNetwork ? lab.normalizedHost : nil,
                   icon: "desktopcomputer", action: .cancel)
        } else if isSetup && lab.discoveryError == nil && lab.discovered.isEmpty {
            status(lab.isDiscovering ? "Searching nearby…" : "No Macs found",
                   detail: "Open SlopZooka on your Mac.", icon: "desktopcomputer")
        }
        if showsMacPicker {
            if let message = lab.discoveryError, !lab.needsPairing {
                status("Discovery unavailable", detail: "You can still enter your Mac’s address.", icon: "exclamationmark", color: .orange)
                errorDetails(message)
            }
            if lab.method == .localNetwork && !lab.isDiscovering && lab.phase == .idle && lab.discovered.isEmpty {
                Button("Search Again", action: lab.findMacs).buttonStyle(.bordered)
            }
            if isPicker && lab.isDiscovering {
                Text("Searching for nearby Macs…").font(.subheadline).foregroundStyle(.secondary)
            } else if isPicker && lab.method == .localNetwork && lab.phase != .checking {
                if lab.discovered.isEmpty && lab.discoveryError == nil {
                    Text("No Macs found").foregroundStyle(.secondary)
                }
                Button("Search Again", action: lab.findMacs)
                    .buttonStyle(.bordered).disabled(!lab.canChangeConnection)
            }
        }
    }

    private func status(_ label: String, detail: String?, icon: String, color: Color = .cyan, action: StatusAction? = nil) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 52, height: 52)
                    .background(color.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).font(.title3.weight(.semibold))
                    if let detail { Text(detail).foregroundStyle(.secondary) }
                }
            }
            .accessibilityElement(children: .combine)
            if let action {
                Spacer(minLength: 0)
                switch action {
                case .cancel: cancelButton
                case .retry: retryButton
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
    }

    private var cancelButton: some View {
        Button("Cancel", action: lab.cancelConnection)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var retryButton: some View {
        Button(action: lab.connect) {
            Image(systemName: "arrow.clockwise")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Try Again")
        .help("Try Again")
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lab.isPairing {
                HStack {
                    Text("Checking code…").font(.headline)
                    Spacer()
                    cancelButton
                }
            } else {
                Text("Enter the six-digit code shown on your Mac.").font(.headline)
            }
            PairingCodeField()
            if let error = lab.pairingError {
                let message = error.split(separator: "\n", maxSplits: 1).last.map(String.init) ?? error
                Text(message).foregroundStyle(.orange)
                errorDetails(error)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
    }

    private func connectionFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            status(
                lab.phase.isReconnecting ? "Connection interrupted" : "Couldn’t reach your Mac",
                detail: lab.method == .direct && isSetup ? "Pair over Local Network before using Direct." : nil,
                icon: "exclamationmark",
                color: .orange,
                action: lab.normalizedHost.isEmpty ? nil : .retry
            )
            if lab.method == .direct && !isPicker {
                Button("Use Local Network") { lab.changeMethod(.localNetwork) }
                    .buttonStyle(.bordered)
            }
            errorDetails(message)
        }
    }

    private var discoveredMacs: some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Macs").font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(lab.discovered) { mac in
                Button {
                    selectMac(mac.address)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        Text(mac.rawValue)
                        Spacer(minLength: 0)
                        if lab.mac == mac && (lab.isReady || lab.needsPairing) {
                            Image(systemName: "checkmark")
                                .accessibilityLabel(lab.isReady ? "Connected Mac" : "Selected Mac")
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(.white.opacity(0.05), in: shape)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .contentShape([.interaction, .hoverEffect], shape)
                    .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .disabled(!lab.canChangeConnection || lab.phase == .checking || (lab.mac == mac && (lab.isReady || lab.needsPairing)))
            }
        }
    }

    private var connectionOptions: some View {
        let showsManualAddress = lab.method == .localNetwork && showsMacPicker
        let showsChooseMac = !showsMacPicker
        let radius: CGFloat = 16
        return VStack(alignment: .leading, spacing: 0) {
            if showsManualAddress {
                Button {
                    showManualAddress.toggle()
                } label: {
                    optionLabel("Enter address manually", symbol: showManualAddress ? "chevron.down" : "chevron.right",
                                topRadius: radius, bottomRadius: 0)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showManualAddress ? "Expanded" : "Collapsed")
                if showManualAddress {
                    HStack(spacing: 12) {
                        TextField("MacName.local:7777", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { if canFindMac { selectMac(address) } }
                        Button("Find Mac") { selectMac(address) }
                            .disabled(!canFindMac)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                Divider()
            }
            if showsChooseMac {
                NavigationLink(value: ConnectionPage.chooseMac) {
                    optionLabel("Choose Another Mac", symbol: "chevron.right", topRadius: radius, bottomRadius: 0)
                }
                .buttonStyle(.plain)
                .disabled(!lab.canChangeConnection || lab.phase == .checking)
                Divider()
            }
            NavigationLink(value: ConnectionPage.options) {
                optionLabel("Connection options", symbol: "chevron.right",
                            topRadius: showsManualAddress || showsChooseMac ? 0 : radius, bottomRadius: radius)
            }
            .buttonStyle(.plain)
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: radius))
    }

    private func optionLabel(_ title: String, symbol: String, topRadius: CGFloat, bottomRadius: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius
        )
        return HStack {
            Text(title)
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60)
        .contentShape([.interaction, .hoverEffect], shape)
        .hoverEffect(.highlight)
    }

    private var connectionDetails: some View {
        let radius: CGFloat = 16
        return VStack(alignment: .leading, spacing: 0) {
            if let origin = lab.healthOrigin {
                detailRow("Address", value: origin)
                Divider()
                detailRow("Logs", value: "/Users/demo/.slopzooka/logs/companion.jsonl")
                Divider()
            }
            if let error = lab.layoutError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(16)
                Divider()
            }
            Button {
                lab.reload()
            } label: {
                optionLabel("Reload All Window Content", symbol: "arrow.clockwise",
                            topRadius: lab.healthOrigin == nil && lab.layoutError == nil ? radius : 0,
                            bottomRadius: radius)
            }
            .buttonStyle(.plain)
            .disabled(!lab.isReady)
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: radius))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
    }

    private func errorDetails(_ message: String) -> some View {
        DisclosureGroup("Details") {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private var canFindMac: Bool {
        lab.canChangeConnection && lab.phase != .checking && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectMac(_ host: String) {
        address = host
        lab.select(host)
    }

}

private struct ConnectionOptionsPage: View {
    @Environment(LabModel.self) private var lab
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(ConnectionMethod.allCases) { method in
                    methodRow(method)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Connection options")
    }

    private func methodRow(_ method: ConnectionMethod) -> some View {
        let selected = lab.method == method
        let shape = RoundedRectangle(cornerRadius: 22)
        return Button {
            lab.changeMethod(method)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: method == .localNetwork ? "wifi" : "desktopcomputer")
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(method.rawValue)
                    if method == .direct {
                        Text("Experimental · Requires pairing over Local Network")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(.white.opacity(selected ? 0.12 : 0.05), in: shape)
            .contentShape([.interaction, .hoverEffect], shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(!lab.canChangeConnection || lab.phase == .checking)
    }
}

private struct PairingCodeField: View {
    @Environment(LabModel.self) private var lab
    @FocusState private var focused: Bool

    var body: some View {
        TextField("6-digit code", text: Binding(get: { lab.pairingCode }, set: { lab.enterCode($0) }))
            .font(.system(size: 32, weight: .medium, design: .monospaced))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .disabled(lab.isPairing)
            .task(id: lab.normalizedHost) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = !lab.isPairing
                lab.requestCodeDisplay()
            }
            .onChange(of: lab.isPairing) { _, pairing in
                if !pairing { focused = true }
            }
    }
}
