import SwiftUI

struct HealthStatusView: View {
    let state: HealthState
    @State private var isDetailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .idle:
                Label("Not connected", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)

            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to Mac…")
                }

            case .success(let response):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Companion reachable", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    DisclosureGroup(isExpanded: $isDetailsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            detailRow(label: "Origin", value: response.controlOrigin)
                            detailRow(label: "Hostname", value: response.hostname)

                            if let workspacesRoot = response.workspacePaths?.workspacesRoot {
                                detailRow(label: "Workspaces", value: workspacesRoot)
                            }

                            detailRow(label: "Logs", value: response.logFilePath)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Connection Details")
                            .font(.footnote.weight(.semibold))
                    }
                }

            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}
