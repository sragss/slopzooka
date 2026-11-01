import SwiftUI
import UIKit

/// Native scene mechanics live here; window intent and recovery live in WindowGateway.
struct WindowScene<Content: View>: View {
    @ObservedObject var windows: WindowGateway
    var id: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(SceneIdentity(reference: id.flatMap { windows.reference(for: $0) }, onRestore: windows.remember))
            .modifier(SceneActions(windows: windows, id: id))
    }
}

struct ImmersiveWorkspaceScene: View {
    @ObservedObject var windows: WindowGateway

    var body: some View {
        WristWorkspaceView()
            .modifier(SceneActions(windows: windows))
            .onAppear { windows.immersiveWorkspace.observe(isPresented: true) }
            .onDisappear { windows.immersiveWorkspace.observe(isPresented: false) }
    }
}

/// Both scene types can present windows, even after the launcher has been closed.
private struct SceneActions: ViewModifier {
    @ObservedObject var windows: WindowGateway
    var id: String? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var phase
    @State private var presenterID = UUID()

    func body(content: Content) -> some View {
        content
            .environmentObject(windows)
            .environmentObject(windows.launcher)
            .environmentObject(windows.discovery)
            .environmentObject(windows.immersiveWorkspace)
            .onAppear { update(); windows.start() }
            .onChange(of: phase) { _, _ in update() }
            .onDisappear {
                windows.detachPresenter(presenterID)
                windows.observe(id: id, isPresented: false, isFocused: false)
            }
    }
    private func update() {
        // Register observed scenes before reconciling, avoiding duplicate restore requests.
        windows.observe(id: id, isPresented: phase != .background, isFocused: phase == .active)
        if phase != .active { windows.detachPresenter(presenterID); return }
        windows.attachPresenter(presenterID) { kind, value, opening in
            if opening {
                if let value { openWindow(id: kind, value: value) } else { openWindow(id: kind) }
            } else if let value { dismissWindow(id: kind, value: value) }
        }
    }
}

/// Native immersive actions stay in this scene adapter, shared by Settings and the wrist.
struct ImmersiveWorkspaceControl: View {
    var exitOnly = false
    @EnvironmentObject private var windows: WindowGateway
    @EnvironmentObject private var workspace: ImmersiveWorkspaceState
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Group {
            if exitOnly {
                Button("Exit Immersive Workspace", systemImage: "arrow.uturn.backward") { changeMode(false) }
            } else {
                Toggle("Immersive workspace", isOn: Binding(
                    get: { workspace.isPresented }, set: changeMode))
            }
        }
        .disabled(workspace.isTransitioning)
    }

    private func changeMode(_ enabled: Bool) {
        Task {
            await workspace.setEnabled(enabled, open: {
                switch await openImmersiveSpace(id: ImmersiveWorkspaceState.sceneID) {
                case .opened: return .opened
                case .userCancelled: return .cancelled
                case .error: return .failed
                @unknown default: return .failed
                }
            }, dismiss: {
                // Keep a way back when the wrist is the last remaining scene.
                windows.openLauncher()
                await dismissImmersiveSpace()
            })
        }
    }
}

private let referenceKey = "SlopZooka.windowReference.v1"

private struct SceneIdentity: UIViewRepresentable {
    let reference: WindowReference?
    let onRestore: (WindowReference) -> Void
    func makeUIView(context: Context) -> IdentityView { IdentityView() }
    func updateUIView(_ view: IdentityView, context: Context) {
        view.reference = reference
        view.onRestore = onRestore
        view.recordIdentity()
    }

    final class IdentityView: UIView {
        var reference: WindowReference?
        var onRestore: ((WindowReference) -> Void)?
        private var restored = false
        override func didMoveToWindow() { super.didMoveToWindow(); recordIdentity() }
        func recordIdentity() {
            guard let session = window?.windowScene?.session else { return }
            guard let reference else {
                if !restored, let data = session.userInfo?[referenceKey] as? Data,
                    let saved = try? JSONDecoder().decode(WindowReference.self, from: data) {
                    restored = true
                    DispatchQueue.main.async { self.onRestore?(saved) }
                }
                return
            }
            guard let data = try? JSONEncoder().encode(reference) else { return }
            var info = session.userInfo ?? [:]
            info[referenceKey] = data
            session.userInfo = info
        }
    }
}

final class WindowApplicationDelegate: NSObject, UIApplicationDelegate {
    let windows = WindowGateway()
    func application(_ application: UIApplication, didDiscardSceneSessions sessions: Set<UISceneSession>) {
        // Discard is permanent scene closure. Disconnect/background/onDisappear are not.
        // UIKit may deliver this on the next launch, so read the identity from the session.
        for session in sessions {
            guard let data = session.userInfo?[referenceKey] as? Data,
                let reference = try? JSONDecoder().decode(WindowReference.self, from: data) else { continue }
            // An older instance can finish closing after the same content was reopened.
            let replacementExists = application.connectedScenes.contains { scene in
                guard scene.session.persistentIdentifier != session.persistentIdentifier,
                    let replacement = scene.session.userInfo?[referenceKey] as? Data else { return false }
                return (try? JSONDecoder().decode(WindowReference.self, from: replacement)) == reference
            }
            if replacementExists { continue }
            windows.close(reference, dismiss: false)
        }
    }
}

struct WindowRecoveryView: View {
    let id: String?
    @EnvironmentObject private var windows: WindowGateway
    var body: some View {
        ContentUnavailableView {
            Label("Reconnect Window", systemImage: "network")
        } description: {
            Text(id.map { windows.message(for: $0) } ?? "Open a terminal or frontend from the launcher.")
        } actions: {
            Button("Retry") { windows.reload(id: id) }
            Button("Open Launcher") { windows.openLauncher() }
            if let id, windows.reference(for: id) != nil { Button("Close Window") { windows.close(id: id) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
