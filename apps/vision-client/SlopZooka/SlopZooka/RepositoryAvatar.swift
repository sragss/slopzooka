import SwiftUI

struct RepositoryAvatar: View {
    let urlString: String
    @State private var retriedURL: URL?
    private let log = AppLog("repository-avatar")

    var body: some View {
        Group {
            if !urlString.isEmpty, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        Circle().fill(.quaternary)
                            .overlay { ProgressView().scaleEffect(0.75) }
                    case let .failure(error):
                        fallback
                            .task(id: url) { await handleFailure(error, url: url) }
                    @unknown default:
                        fallback
                    }
                }
                .id(retriedURL == url)
            } else {
                fallback
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Circle().fill(.quaternary)
            .overlay {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
    }

    private func handleFailure(_ error: Error, url: URL) async {
        let networkError = error as? URLError
        let transient: Set<URLError.Code> = [
            .cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        ]
        if retriedURL != url, let code = networkError?.code, transient.contains(code) {
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            retriedURL = url
            return
        }
        if networkError?.code != .cancelled {
            let failure = error as NSError
            log.warn("avatar.load.failed", ["errorDomain": failure.domain, "code": String(failure.code)])
        }
    }
}
