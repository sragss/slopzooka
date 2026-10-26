import SwiftUI

struct WorkspaceRowView: View {
    let workspace: WorkspaceSummary
    let selectedTool: LaunchTarget
    let isBusy: Bool

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

                    if !workspace.existsOnDisk {
                        Text("Missing on Mac")
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
        .contentShape(Rectangle())
        .accessibilityLabel("Open \(workspace.repo.nameWithOwner), \(workspace.branchName), with \(selectedTool.title)")
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
