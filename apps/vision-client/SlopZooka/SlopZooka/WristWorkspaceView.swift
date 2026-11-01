import RealityKit
import SwiftUI

struct WristWorkspaceView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState

    var body: some View {
        RealityView { content, attachments in
            #if targetEnvironment(simulator)
            // The simulator has no tracked wrist. Exercise the real UI at a fixed location.
            let anchor = AnchorEntity(.head, trackingMode: .once)
            if let menu = attachments.entity(for: "wrist-menu") {
                menu.position = [0, -0.15, -0.65]
                menu.scale = .init(repeating: 0.65)
                anchor.addChild(menu)
            }
            content.add(anchor)
            #else
            for wrist in ImmersiveWorkspaceState.Wrist.allCases {
                let anchor = AnchorEntity(.hand(wrist == .left ? .left : .right, location: .wrist),
                    trackingMode: .continuous)
                anchor.name = wrist.rawValue
                content.add(anchor)
            }
            mountMenu(in: content, attachments: attachments)
            #endif
        } update: { content, attachments in
            #if !targetEnvironment(simulator)
            mountMenu(in: content, attachments: attachments)
            #endif
        } attachments: {
            Attachment(id: "wrist-menu") {
                WristMenuView()
                    .environmentObject(windows)
                    .environmentObject(workspace)
            }
        }
    }

    private func mountMenu(in content: RealityViewContent, attachments: RealityViewAttachments) {
        guard let menu = attachments.entity(for: "wrist-menu"),
            let anchor = content.entities.first(where: { $0.name == workspace.wrist.rawValue }) else { return }
        guard menu.parent !== anchor else { return }
        anchor.addChild(menu)
        let isLeft = workspace.wrist == .left
        // Wrist +Y points out of the back of the hand; +Z points toward the thumb.
        // Face away from the wrist, with the top toward the fingers on either hand.
        // Bias toward the forearm to leave the system's hand overlays clear.
        menu.position = [isLeft ? -0.12 : 0.12, 0.045, 0]
        menu.orientation = simd_quatf(angle: isLeft ? -.pi / 2 : .pi / 2, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        menu.scale = .init(repeating: 0.6)
    }
}

private struct WristMenuView: View {
    @EnvironmentObject private var windows: WindowGateway
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.cyan)
                Text("SlopZooka").font(.headline)
                Spacer()
            }
            Button { windows.openLauncher() } label: {
                Label("Open Launcher", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)

            if windows.terminalSessions.isEmpty {
                Text("Open the launcher to choose a project.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("RECENT TERMINALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(windows.terminalSessions.prefix(3)) { session in
                    Button {
                        do { try windows.open(id: session.id); error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        Label(session.payload.title, systemImage: "terminal")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open terminal, \(session.payload.title)")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            ImmersiveWorkspaceControl(exitOnly: true)
                .font(.subheadline)
            #if targetEnvironment(simulator)
            Text("Wrist tracking requires Apple Vision Pro.")
                .font(.caption2).foregroundStyle(.secondary)
            #endif
        }
        .padding(20)
        .frame(width: 320)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }
}
