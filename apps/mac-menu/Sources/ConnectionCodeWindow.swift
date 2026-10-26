import AppKit
import SwiftUI

/// A brief, non-activating code display: never steals focus from the user's Mac app.
@MainActor
final class ConnectionCodeWindow {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func update(until: TimeInterval, model: CompanionModel) {
        dismissal?.cancel()
        let remaining = until - Date().timeIntervalSince1970
        guard model.ready, remaining > 0 else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: ConnectionCodeView(model: model) { [weak self] in
                self?.panel?.orderOut(nil)
            })
            panel = window
        }
        panel?.center()
        panel?.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}

private struct ConnectionCodeView: View {
    @ObservedObject var model: CompanionModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Connect Vision Pro", systemImage: "visionpro")
                    .font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss connection code")
            }
            Text(model.code)
                .font(.system(size: 48, weight: .medium, design: .monospaced))
                .tracking(8)
                .accessibilityLabel("Connection code \(model.code.map(String.init).joined(separator: " "))")
            Text("Enter these six digits in SlopZooka on your headset.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 420, height: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
