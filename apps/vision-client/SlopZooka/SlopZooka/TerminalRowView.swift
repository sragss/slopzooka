import SwiftUI

struct TerminalRowView: View {
    let session: TerminalSessionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(session.payload.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if session.isFocused {
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                    Text(status)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Spacer()

            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open terminal, \(session.payload.displayTitle)")
        .accessibilityValue(status)
    }

    private var status: String {
        switch session.loadState {
        case .ended:
            return "Session ended"
        case .failed:
            return session.isPresented ? "Connection needs attention" : "Reopen to reconnect"
        case .disconnected:
            return "Mac companion disconnected"
        case .loading:
            return session.isPresented ? "Connecting…" : "Reopen to connect"
        case .idle, .loaded:
            if session.isFocused { return "Receiving input" }
            return session.isPresented ? "Window open" : "Ready to reopen"
        }
    }
}
