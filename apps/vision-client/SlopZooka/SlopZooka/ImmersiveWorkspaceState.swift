import Combine
import Foundation

/// App-local scene lifecycle. Never part of the companion's desired window layout.
@MainActor
final class ImmersiveWorkspaceState: ObservableObject {
    static let sceneID = "immersive-workspace"
    enum Phase { case inactive, opening, active, closing }
    enum OpenResult { case opened, cancelled, failed }
    enum Wrist: String, CaseIterable, Identifiable {
        case left, right
        var id: Self { self }
        var title: String { self == .left ? "Left" : "Right" }
    }

    @Published private(set) var phase: Phase = .inactive
    @Published private(set) var error: String?
    @Published var wrist: Wrist {
        didSet { defaults.set(wrist.rawValue, forKey: "wristMenuHand") }
    }
    private let defaults: UserDefaults
    private var transitionID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wrist = Wrist(rawValue: defaults.string(forKey: "wristMenuHand") ?? "") ?? .left
    }

    var isEnabled: Bool { phase == .opening || phase == .active }
    var isTransitioning: Bool { phase == .opening || phase == .closing }

    func setEnabled(_ enabled: Bool, open: () async -> OpenResult, dismiss: () async -> Void) async {
        guard !isTransitioning, enabled != isEnabled else { return }
        let requestID = UUID()
        transitionID = requestID
        error = nil
        if enabled {
            phase = .opening
            let result = await open()
            // A scene can disappear and another request start before this reply arrives.
            guard transitionID == requestID else { return }
            switch result {
            case .opened: phase = .active
            case .cancelled: phase = .inactive
            case .failed:
                phase = .inactive
                error = "Couldn’t open the immersive workspace. Try again."
            }
        } else {
            phase = .closing
            await dismiss()
            guard transitionID == requestID else { return }
            phase = .inactive
        }
    }

    func didAppear() {
        // Leave an outstanding open request locked until its result returns.
        if phase == .inactive { phase = .active }
    }

    func didDisappear() {
        // The native dismiss call may finish after onDisappear. Keep new opens locked
        // until it returns, so an old dismissal cannot close a newly opened space.
        if phase == .closing { return }
        transitionID = UUID()
        phase = .inactive
    }
}
