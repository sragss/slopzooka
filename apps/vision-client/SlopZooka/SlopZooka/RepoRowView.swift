import SwiftUI

struct RepoRowView: View {
    let repo: RecentRepoSummary
    let isBusy: Bool
    let isSelectedToolTerminal: Bool

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(repo.name)
                        .font(.headline)

                    if repo.isPrivate {
                        Label("Private", systemImage: "lock.fill")
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(repo.nameWithOwner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("\(repo.owner.name ?? repo.owner.login) • updated \(Self.timestampFormatter.string(from: repo.pushedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(isSelectedToolTerminal ? "Open Shell" : "Launch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let branch = repo.defaultBranch {
                    Text(branch)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

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
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 52, height: 52)
        }
    }
}
