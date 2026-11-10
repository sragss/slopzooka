import RealityKit
import SwiftUI

private let wristAccent = Color("AccentHighlight")

enum Wrist: String, CaseIterable { case left, right }

struct WristWorkspaceView: View {
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @AppStorage("wristMenuHand") private var wrist: Wrist = .left

    var body: some View {
        let terminalCount = min(windows.terminalSessions.count, 3)
        RealityView { content in
            let anchor = AnchorEntity()
            let menu = Entity()
            menu.addChild(attachment("launcher", view: WristLauncherControl()))
            for index in 0..<3 {
                menu.addChild(attachment("terminal-\(index)", view: WristTerminalControl(index: index)))
            }
            menu.addChild(attachment("empty", view: Text("Open the launcher to choose a project.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(width: 240)))
            menu.addChild(attachment("exit", view: ImmersiveWorkspaceControl(exitOnly: true)
                .font(.subheadline).buttonStyle(.bordered).controlSize(.regular)))
            anchor.addChild(menu)
            configure(anchor, terminalCount: terminalCount)
            content.add(anchor)
        } update: { content in
            if let anchor = content.entities.first as? AnchorEntity {
                configure(anchor, terminalCount: terminalCount)
            }
        }
    }

    private func attachment<V: View>(_ name: String, view: V) -> Entity {
        let entity = Entity()
        entity.name = name
        entity.components.set(ViewAttachmentComponent(rootView: view
            .environmentObject(windows).environmentObject(workspace)))
        return entity
    }

    private func configure(_ anchor: AnchorEntity, terminalCount: Int) {
        guard let menu = anchor.children.first else { return }
        #if targetEnvironment(simulator)
        let anchoring = AnchoringComponent(.head, trackingMode: .once)
        menu.position = [0, -0.15, -0.65]
        #else
        let isLeft = wrist == .left
        let anchoring = AnchoringComponent(.hand(isLeft ? .left : .right, location: .wrist), trackingMode: .continuous)
        // Wrist +Y points out of the hand and +Z toward the thumb. Face outward,
        // top toward the fingers. Keep the controls near the wrist, not down the forearm.
        menu.position = [isLeft ? -0.035 : 0.035, 0.06, 0]
        menu.orientation = simd_quatf(angle: isLeft ? -.pi / 2 : .pi / 2, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        #endif
        if anchor.anchoring != anchoring { anchor.anchoring = anchoring }
        menu.scale = .init(repeating: 0.6)

        // Separate attachments give the controls real depth and independent hit surfaces.
        // Reposition existing entities so tracking updates never rebuild their SwiftUI state.
        menu.findEntity(named: "launcher")?.position = [0, 0.095, 0.035]
        menu.findEntity(named: "exit")?.position = [0, -0.085, 0.015]
        menu.findEntity(named: "empty")?.isEnabled = terminalCount == 0
        for index in 0..<3 {
            guard let tile = menu.findEntity(named: "terminal-\(index)") else { continue }
            tile.isEnabled = index < terminalCount
            let column = Float(index) - Float(terminalCount - 1) / 2
            tile.position = [column * 0.105, abs(column) * 0.012, 0.02 - abs(column) * 0.018]
            tile.orientation = simd_quatf(angle: -column * 0.22, axis: [0, 1, 0])
        }
    }
}

private struct WristLauncherControl: View {
    @EnvironmentObject private var windows: WindowGateway

    var body: some View {
        Button(action: windows.openLauncher) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [wristAccent.opacity(0.3), wristAccent.opacity(0.1), .clear],
                        center: .topLeading, startRadius: 0, endRadius: 120))
                    .padding(8)
                Circle().trim(from: 0.08, to: 0.92)
                    .stroke(AngularGradient(colors: [wristAccent.opacity(0.1), wristAccent, .white, wristAccent.opacity(0.1)],
                        center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(90)).padding(5)
                VStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 30, weight: .medium))
                    Text("Launcher").font(.caption.weight(.semibold))
                }
            }
            .frame(width: 120, height: 120)
        }
        .buttonStyle(WristControlStyle(shape: Circle()))
        .accessibilityLabel("Open Launcher")
    }
}

private struct WristTerminalControl: View {
    let index: Int
    @EnvironmentObject private var windows: WindowGateway
    @State private var error: String?

    var body: some View {
        if let session = windows.terminalSessions.dropFirst(index).first {
            VStack(spacing: 8) {
                Button {
                    do { try windows.open(id: session.id); error = nil }
                    catch { self.error = error.localizedDescription }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "terminal.fill").font(.title3)
                                .foregroundStyle(session.isFocused ? .green : wristAccent)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(session.payload.displayTitle)
                            .font(.caption.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(session.isFocused ? "ACTIVE" : "TERMINAL")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.5).foregroundStyle(.secondary)
                    }
                    .padding(14).frame(width: 132, height: 132, alignment: .topLeading)
                    .background(wristAccent.opacity(session.isFocused ? 0.13 : 0.04),
                        in: RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(WristControlStyle(shape: RoundedRectangle(cornerRadius: 22)))
                .accessibilityLabel("Open terminal, \(session.payload.displayTitle)")
                if let error {
                    Text(error).font(.caption2).foregroundStyle(.orange).frame(width: 160)
                }
            }
            .onChange(of: session.id) { _, _ in error = nil }
        }
    }
}

/// One shape owns the glass, hit target, and gaze feedback, including rounded corners.
private struct WristControlStyle<S: InsettableShape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape([.interaction, .hoverEffect], shape)
            .glassBackgroundEffect(in: shape)
            .overlay {
                shape.fill(wristAccent.opacity(0.12))
                    .overlay { shape.strokeBorder(wristAccent.opacity(0.9), lineWidth: 2) }
                    .hoverEffect { effect, isActive, _ in
                        effect.opacity(isActive ? 1 : 0)
                    }
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .hoverEffect { effect, isActive, _ in
                effect.scaleEffect(isActive ? 1.035 : 1)
            }
            .hoverEffectGroup()
    }
}
