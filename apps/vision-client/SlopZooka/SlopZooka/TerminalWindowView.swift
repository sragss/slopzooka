import SwiftUI

struct TerminalWindowView: View {
    let payload: TerminalWindowPayload
    @State private var loadState: TerminalLoadState = .idle

    var body: some View {
        Group {
            if let url = payload.url {
                CompanionWebView(url: url, loadState: $loadState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Invalid Terminal URL",
                    systemImage: "exclamationmark.triangle",
                    description: Text("SlopZooka could not open the terminal surface.")
                )
            }
        }
    }
}
