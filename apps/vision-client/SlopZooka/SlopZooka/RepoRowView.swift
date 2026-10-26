import SwiftUI

struct RepoRowView: View {
    let repo: RecentRepoSummary
    let isBusy: Bool
    let isSelectedToolTerminal: Bool

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(repo.nameWithOwner)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if repo.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .accessibilityLabel("Private repository")
                            .foregroundStyle(.secondary)
                    }
                }

                Text(repo.defaultBranch ?? "Repository")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())

            }

            Spacer()

            if isBusy {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
            }

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(isSelectedToolTerminal ? "Open shell in" : "Open") \(repo.nameWithOwner)")
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = URL(string: repo.owner.avatarUrl) {
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
