import SwiftUI

struct RepositoryAvatar: View {
    let owner: String?
    let hostID: String?
    var fallbackIcon = "folder"

    @EnvironmentObject private var client: CompanionClient
    @State private var loaded: (owner: String, image: UIImage)?
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        return cache
    }()

    var body: some View {
        Group {
            if let loaded, loaded.owner == owner {
                Image(uiImage: loaded.image).resizable().scaledToFill()
            } else {
                Circle().fill(.quaternary)
                    .overlay {
                        Image(systemName: fallbackIcon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: RequestID(owner: owner, host: client.current, ready: client.isReady)) {
            guard let owner else { return }
            let key = owner.lowercased() as NSString
            if let image = Self.cache.object(forKey: key) {
                loaded = (owner, image)
            } else if let hostID, client.current?.id == hostID, client.isReady,
                      let data = try? await client.repositoryAvatar(hostID: hostID, owner: owner),
                      !Task.isCancelled, let image = UIImage(data: data) {
                Self.cache.setObject(image, forKey: key)
                loaded = (owner, image)
            }
        }
    }

    private struct RequestID: Equatable {
        let owner: String?
        let host: ConnectedHost?
        let ready: Bool
    }
}
