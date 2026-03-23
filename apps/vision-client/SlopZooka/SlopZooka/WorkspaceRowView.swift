import SwiftUI

struct WorkspaceRowView: View {
    let workspace: WorkspaceSummary
    let selectedTool: LaunchTarget
    let isBusy: Bool

    private static let timestampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(workspace.repo.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(workspace.branchName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }

                Text(workspace.repo.nameWithOwner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("\(workspace.baseRef) • updated \(relativeUpdatedAt)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(selectedTool == .terminal ? "Open Shell" : "Reopen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(workspace.existsOnDisk ? statusText : "missing")
                    .font(.caption2)
                    .foregroundStyle(workspace.existsOnDisk ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                    .lineLimit(1)

                if isBusy {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.quaternary.opacity(0.28))
        )
        .overlay(alignment: .topTrailing) {
            if !workspace.existsOnDisk {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .padding(10)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var relativeUpdatedAt: String {
        Self.timestampFormatter.localizedString(for: workspace.updatedAt, relativeTo: Date())
    }

    private var statusText: String {
        if selectedTool == .terminal {
            return "shell"
        }

        return workspace.profile ?? "workspace"
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = URL(string: workspace.repo.owner.avatarUrl) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.75)
                    }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 52, height: 52)
        }
    }
}
