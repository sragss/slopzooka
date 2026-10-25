import SwiftUI

struct RepoRowView: View {
    let repo: RecentRepoSummary
    let isBusy: Bool
    let isSelectedToolTerminal: Bool

    private let rowShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(repo.name)
                        .font(.headline)

                    if repo.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .accessibilityLabel("Private repository")
                            .foregroundStyle(.secondary)
                    }
                }

                Text(repo.nameWithOwner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            }

            Spacer()

            if isBusy {
                ProgressView()
            } else {
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
            }

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowShape.fill(.quaternary.opacity(0.28)))
        .clipShape(rowShape)
        .contentShape(rowShape)
        .contentShape(.hoverEffect, rowShape)
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
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 36, height: 36)
        }
    }
}
