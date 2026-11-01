import RealityKit
import SwiftUI

enum Wrist: String, CaseIterable { case left, right }

struct WristWorkspaceView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left

    var body: some View {
        RealityView { content in
            let anchor = AnchorEntity()
            let menu = Entity()
            menu.components.set(ViewAttachmentComponent(rootView: WristMenuView()
                .environmentObject(windows).environmentObject(workspace)))
            anchor.addChild(menu)
            configure(anchor)
            content.add(anchor)
        } update: { content in
            if let anchor = content.entities.first as? AnchorEntity { configure(anchor) }
        }
    }

    private func configure(_ anchor: AnchorEntity) {
        guard let menu = anchor.children.first else { return }
        #if targetEnvironment(simulator)
        let anchoring = AnchoringComponent(.head, trackingMode: .once)
        menu.position = [0, -0.15, -0.65]
        #else
        let isLeft = wrist == .left
        let anchoring = AnchoringComponent(.hand(isLeft ? .left : .right, location: .wrist), trackingMode: .continuous)
        // Wrist +Y points out of the hand and +Z toward the thumb. Face outward,
        // top toward the fingers; offset toward the forearm to clear system overlays.
        menu.position = [isLeft ? -0.12 : 0.12, 0.045, 0]
        menu.orientation = simd_quatf(angle: isLeft ? -.pi / 2 : .pi / 2, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        #endif
        if anchor.anchoring != anchoring { anchor.anchoring = anchoring }
        menu.scale = .init(repeating: 0.6)
    }
}

private struct WristMenuView: View {
    @EnvironmentObject private var windows: WindowGateway
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SlopZooka", systemImage: "square.stack.3d.up.fill").font(.headline)
            Button("Open Launcher", systemImage: "square.grid.2x2", action: windows.openLauncher)
                .buttonStyle(.borderedProminent).tint(.cyan)

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
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(20)
        .frame(width: 320)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }
}
