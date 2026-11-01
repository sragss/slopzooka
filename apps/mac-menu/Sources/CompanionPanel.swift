import AppKit
import ServiceManagement
import SwiftUI

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    private static let icon = CompanionIcon.image(size: 36, application: true)

    var body: some View {
        VStack(spacing: 0) {
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
                        model.openDashboard()
                    } label: {
                        HStack {
                            Text(model.openingDashboard ? "Opening…" : "Open Dashboard")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.openingDashboard)
                    if let error = model.dashboardError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }

                    Text(model.code)
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Connection code")
                        .accessibilityValue(model.code)
                        .frame(maxWidth: .infinity, alignment: .center)
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
            }
            .padding(18)

            Divider()

            HStack {
                Menu {
                    Toggle("Start at Login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    Button("View Logs…") { NSWorkspace.shared.open(model.logDirectory) }
                    Button("Login Settings…") { SMAppService.openSystemSettingsLoginItems() }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
            }
            .font(.callout)
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
    }

    private func activity(_ count: Int, title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Text(count, format: .number).font(.system(size: 22, weight: .semibold, design: .rounded))
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
