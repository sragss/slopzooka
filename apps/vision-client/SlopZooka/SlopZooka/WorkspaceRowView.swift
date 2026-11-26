import SwiftUI

struct WorkspaceRowView: View {
    let workspace: WorkspaceSummary
    let selectedTool: LaunchTarget
    let isBusy: Bool
    let sessionCount: Int
    var lastKnown = false

    private var status: String {
        if !workspace.existsOnDisk { return "Missing on Mac" }
        if sessionCount == 1 { return "1 terminal" }
        if sessionCount > 1 { return "\(sessionCount) terminals" }
        return "Available"
    }

    var body: some View {
        HStack(spacing: 12) {
            RepositoryAvatar(urlString: workspace.repo.owner.avatarUrl)
            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.name ?? workspace.branchName)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if workspace.name != nil {
                    Text(workspace.branchName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isBusy {
                ProgressView().scaleEffect(0.8)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    if lastKnown { Text("Last known").font(.caption2).foregroundStyle(.secondary) }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(workspace.existsOnDisk ? Color.primary : .orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityHint(lastKnown ? "Reconnect to open this worktree" : "Opens with \(selectedTool.title)")
    }
}
