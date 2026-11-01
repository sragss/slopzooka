import Combine

/// App-local scene lifecycle. Never part of the companion's desired window layout.
@MainActor
final class ImmersiveWorkspaceState: ObservableObject {
    static let sceneID = "immersive-workspace"
    enum OpenResult { case opened, cancelled, failed }
    @Published private(set) var isPresented = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var error: String?
    private var receivedSceneEvent = false

    func setEnabled(_ enabled: Bool, open: () async -> OpenResult, dismiss: () async -> Void) async {
        guard !isTransitioning, enabled != isPresented else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        receivedSceneEvent = false
        error = nil
        if enabled {
            switch await open() {
            case .opened:
                if !receivedSceneEvent { isPresented = true }
            case .cancelled: break
            case .failed:
                error = "Couldn’t open the immersive workspace. Try again."
            }
        } else {
            await dismiss()
            if !receivedSceneEvent { isPresented = false }
        }
    }

    // Scene events take precedence over action replies; a late success cannot undo dismissal.
    // Results fill the gap when the native call completes before SwiftUI's scene callback.
    func observe(isPresented: Bool) {
        receivedSceneEvent = true
        self.isPresented = isPresented
    }
}
