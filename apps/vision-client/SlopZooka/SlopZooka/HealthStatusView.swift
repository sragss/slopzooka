import SwiftUI

struct HealthStatusView: View {
    let state: HealthState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .idle:
                Label("No health check yet.", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)

            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking companion...")
                }

            case .success(let response):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Companion reachable", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Origin: \(response.controlOrigin)")
                    Text("Hostname: \(response.hostname)")
                    Text("Logs: \(response.logFilePath)")
                        .foregroundStyle(.secondary)
                }

            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }
}
