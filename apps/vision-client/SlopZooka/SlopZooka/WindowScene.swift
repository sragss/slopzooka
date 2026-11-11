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
            .environmentObject(windows.client)
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
        windows.attachPresenter(presenterID) { command in
            switch command {
            case .open(let window): openWindow(id: window.kind.rawValue, value: window.id)
            case .close(let window): dismissWindow(id: window.kind.rawValue, value: window.id)
            case .openLauncher: openWindow(id: "launcher")
            }
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
    let windows: WindowGateway
    let voice: TerminalVoiceController

    override init() {
        let windows = WindowGateway()
        self.windows = windows
        voice = TerminalVoiceController(capture: SpeechCaptureController(),
            isAvailable: { [weak windows] id, mode in
                mode == .rename ? windows?.canRename(id) == true : windows?.canReceiveVoice(id) == true
            },
            rename: { [weak windows] id, name, target in
                guard let windows else { throw CompanionError(message: "Terminal unavailable.") }
                try await windows.rename(id: id, name: name, target: target)
            },
            hostID: { [weak windows] id in windows?.reference(for: id)?.hostID },
            deliver: { [weak windows] command in
                guard let windows else { throw CompanionError(message: "Terminal unavailable.") }
                try await windows.submitVoiceInput(command)
            })
        super.init()
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sessions: Set<UISceneSession>) {
        // Open sessions include archived replacements that have no connected
        // scene yet. Exclude the entire discard batch: two discarded copies
        // must not protect each other from a genuine close.
        let discardedIDs = Set(sessions.map(\.persistentIdentifier))
        func reference(_ session: UISceneSession) -> WindowReference? {
            guard let data = session.userInfo?[referenceKey] as? Data else { return nil }
            return try? JSONDecoder().decode(WindowReference.self, from: data)
        }
        let surviving = application.openSessions.filter { !discardedIDs.contains($0.persistentIdentifier) }
        let remaining = Set(surviving.compactMap(reference))
        AppLog("window-scene").info("scenes.discarded", ["discarded": String(sessions.count),
            "surviving": String(surviving.count), "archived": String(surviving.filter { $0.scene == nil }.count),
            "identified": String(remaining.count)])
        for window in Set(sessions.compactMap(reference)) {
            windows.discardScene(window, remainingScenes: remaining)
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

/// Source geometry, not encoder pixel size, controls streamed-window aspect.
/// Later geometry changes preserve the user's current diagonal scale.
struct PreviewGeometry: UIViewRepresentable {
    let size: CGSize
    func makeUIView(context: Context) -> GeometryView { GeometryView() }
    func updateUIView(_ view: GeometryView, context: Context) { view.sourceSize = size; view.apply() }
    final class GeometryView: UIView {
        var sourceSize = CGSize.zero
        private var lastAspect: CGFloat?
        private var pendingAspect: CGFloat?
        private let geometryKey = "SlopZooka.previewAspect.v1"
        override func layoutSubviews() { super.layoutSubviews(); lockAspectWhenSized() }
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        func apply() {
            guard let scene = window?.windowScene, sourceSize.width > 0, sourceSize.height > 0 else { return }
            let aspect = sourceSize.width / sourceSize.height
            guard aspect.isFinite, aspect >= 0.1, aspect <= 10, lastAspect != aspect else { return }
            let prior = lastAspect ?? (scene.session.userInfo?[geometryKey] as? Double).map { CGFloat($0) }
            lastAspect = aspect
            let current = scene.effectiveGeometry.coordinateSpace.bounds.size
            if prior == aspect, current.height > 0, abs(current.width / current.height - aspect) < 0.01 {
                scene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform)) { error in
                    AppLog("window-scene").error("preview.geometry.failed", error: error)
                }
                return
            }
            let diagonal = prior == nil ? 850 : hypot(current.width, current.height)
            let height = diagonal / sqrt(aspect * aspect + 1)
            let target = CGSize(width: height * aspect, height: height)
            // Establish the new size before uniform resizing freezes its ratio.
            scene.requestGeometryUpdate(.Vision(size: target, resizingRestrictions: .freeform)) { error in
                AppLog("window-scene").error("preview.geometry.failed", error: error)
            }
            pendingAspect = aspect
            lockAspectWhenSized()
        }
        private func lockAspectWhenSized() {
            guard let scene = window?.windowScene, let aspect = pendingAspect else { return }
            let size = scene.effectiveGeometry.coordinateSpace.bounds.size
            guard size.height > 0, abs(size.width / size.height - aspect) < 0.01 else { return }
            pendingAspect = nil
            var info = scene.session.userInfo ?? [:]
            info[geometryKey] = Double(aspect)
            scene.session.userInfo = info
            scene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform)) { error in
                AppLog("window-scene").error("preview.geometry.failed", error: error)
            }
        }
    }
}
