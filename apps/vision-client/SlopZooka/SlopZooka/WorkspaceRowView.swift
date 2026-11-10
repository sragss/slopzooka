import SwiftUI

struct WorkspaceRowView: View {
    let workspace: WorkspaceSummary
    let selectedTool: LaunchTarget
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            RepositoryAvatar(urlString: workspace.repo.owner.avatarUrl)

            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.repo.nameWithOwner)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(workspace.name ?? workspace.branchName)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("Open \(workspace.repo.nameWithOwner), \(workspace.name ?? workspace.branchName), with \(selectedTool.title)")
    }
}
