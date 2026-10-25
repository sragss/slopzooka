import AppKit
import ServiceManagement
import SwiftUI

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    @State private var pairingExpanded = false
    private static let icon = CompanionIcon.image(size: 36, application: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: Self.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SlopZooka").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(model.ready ? model.detail : model.state)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.ready {
                HStack(spacing: 0) {
                    activity(model.sessions, title: "Terminals", symbol: "terminal")
                    Divider().frame(height: 30)
                    activity(model.frontends, title: "Frontends", symbol: "globe")
                }
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                Button {
                    NSWorkspace.shared.open(model.dashboard)
                } label: {
                    HStack {
                        Text("Open Dashboard")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                DisclosureGroup("Pair Vision Pro", isExpanded: $pairingExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter this code in SlopZooka on your headset.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(model.code).font(.system(size: 19, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button {
                                model.copyCode()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                    }.padding(.top, 8)
                }.font(.callout)
            } else {
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.state == "Needs attention" {
                    Button("Try Again") { model.retryStart() }.buttonStyle(.borderedProminent)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let notice = model.loginNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                Button("Open Login Settings…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
            }
            Divider()
            HStack {
                Menu {
                    Toggle("Start at Login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    Button("View Logs…") { NSWorkspace.shared.open(model.logDirectory) }
                    Button("Login Settings…") { SMAppService.openSystemSettingsLoginItems() }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Quit…") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }.font(.callout)
        }
        .padding(18).frame(width: 320)
    }

    private func activity(_ count: Int, title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Text(count, format: .number).font(.system(size: 22, weight: .semibold, design: .rounded))
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
