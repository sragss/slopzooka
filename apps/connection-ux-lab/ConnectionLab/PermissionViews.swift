import SwiftUI

// The permissions and route-dependent availability shown in the production Frontends tab.
struct FrontendPermissionView: View {
    @Environment(LabModel.self) private var lab
    @State private var preview: Preview?

    private enum Preview: String, Identifiable {
        case dashboard = "SlopZooka Dashboard"
        case design = "Interface Kit"
        case orbit = "Orbit Web"
        case notes = "Design notes"

        var id: Self { self }
        var detail: String {
            switch self {
            case .dashboard: "sragss/slopzooka · localhost:5173"
            case .design: "studio/interface-kit · localhost:6006"
            case .orbit: "studio/orbit-web · localhost:3000"
            case .notes: "Notes · Full Mac window"
            }
        }
        var entries: [String] {
            switch self {
            case .dashboard: ["Connection Lab", "Window recovery", "Terminal keyboard"]
            case .design: ["Buttons", "Status badges", "Navigation"]
            case .orbit: ["Overview", "Customers", "Activity"]
            case .notes: ["Pairing", "Connection options", "Reconnecting"]
            }
        }
    }

    private let webPreviews: [Preview] = [.dashboard, .design, .orbit]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Web frontends", systemImage: "globe").font(.headline)
                Spacer()
                Button("Add URL", systemImage: "plus") {}.disabled(true)
            }
            ForEach(webPreviews) { source in
                webPreview(source)
            }
            if lab.capture != .hidden {
                Divider()
                Label("Mac windows", systemImage: "macwindow").font(.headline)
                if let message = lab.capture.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    if lab.capture == .permission {
                        Button("Allow Screen Recording on Mac") { lab.requestCapture(settings: false) }
                        Button("Open Mac Privacy Settings") { lab.requestCapture(settings: true) }
                    }
                }
                if lab.capture == .ready {
                    Button { preview = .notes } label: {
                        VStack(alignment: .leading) {
                            Text("Design notes").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("Notes · Full Mac window").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .modifier(LabRowSurface())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $preview) { source in
            NavigationStack {
                List(source.entries, id: \.self) { entry in
                    Label(entry, systemImage: "square.grid.2x2")
                }
                .navigationTitle(source.rawValue)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { preview = nil }
                    }
                }
            }
            .frame(width: 620, height: 460)
        }
    }

    private func webPreview(_ source: Preview) -> some View {
        Button { preview = source } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.rawValue).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if lab.method == .direct {
                        Text("Web previews require Local Network. This restriction does not apply to Mac window streams.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(source.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lab.method == .direct)
        .hoverEffectDisabled()
        .modifier(LabRowSurface())
    }
}

struct VoicePermissionView: View {
    @Environment(LabModel.self) private var lab
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if lab.voicePermission == .granted {
                askContent
            } else {
                permissionScreen
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        .onDisappear(perform: lab.cancelVoiceRequest)
        .ornament(attachmentAnchor: .scene(.bottomTrailing), contentAlignment: .bottomLeading) {
            if lab.voicePermission == .granted {
                Button {
                    lab.voiceActive.toggle()
                } label: {
                    Image(systemName: lab.voiceActive ? "stop.fill" : "mic.fill").frame(width: 56, height: 56)
                }
                .accessibilityLabel(lab.voiceActive ? "Stop Voice Input" : "Microphone")
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(!lab.isReady)
                .padding(12)
            }
        }
    }

    private var permissionScreen: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.cyan)
                .frame(width: 76, height: 76)
                .background(.cyan.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(permissionTitle)
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(permissionMessage)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Not Now") {
                    lab.cancelVoiceRequest()
                    dismissWindow(id: "ask")
                }
                .buttonStyle(.bordered)

                if !lab.isRequestingVoice {
                    Button(lab.voicePermission == .undetermined ? "Enable Microphone" : "Check Again",
                           action: lab.requestVoice)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }

    private var permissionTitle: String {
        if lab.isRequestingVoice { return "Waiting for permission…" }
        switch lab.voicePermission {
        case .microphoneDenied: return "Microphone access is off"
        case .speechDenied: return "Speech recognition is off"
        case .undetermined, .granted: return "Talk to SlopZooka"
        }
    }

    private var permissionMessage: String {
        if lab.isRequestingVoice { return "Allow access to continue to Ask." }
        switch lab.voicePermission {
        case .microphoneDenied: return "Allow microphone access for SlopZooka in visionOS Settings."
        case .speechDenied: return "Allow speech recognition for SlopZooka in visionOS Settings."
        case .undetermined, .granted: return "Ask uses your microphone and speech recognition to turn what you say into a request."
        }
    }

    private var askContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask SlopZooka").font(.title3.weight(.semibold))
            Text("Global").font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(lab.isReady ? "Ready" : "Connect to your Mac")
                        .font(.subheadline.weight(.medium))
                    Text("Hold the microphone and say what you need.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}
