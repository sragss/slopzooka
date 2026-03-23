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
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.repo.nameWithOwner)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(workspace.branchName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())

                    Text("updated \(relativeUpdatedAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !workspace.existsOnDisk {
                        Text("missing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.quaternary.opacity(0.28))
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var relativeUpdatedAt: String {
        Self.timestampFormatter.localizedString(for: workspace.updatedAt, relativeTo: Date())
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
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 40, height: 40)
        }
    }
}
