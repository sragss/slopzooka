import SwiftUI

struct RepositoryAvatar: View {
    let urlString: String

    var body: some View {
        Group {
            if !urlString.isEmpty, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(.quaternary)
                        .overlay { ProgressView().scaleEffect(0.75) }
                }
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}
