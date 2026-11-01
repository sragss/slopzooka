import SwiftUI

@main
struct TerminalZoomChecks {
    static func main() {
        let name = "TerminalZoomChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = AppStorage(wrappedValue: TerminalZoom.initialDefaultSteps,
            TerminalZoom.defaultStepsKey, store: defaults)
        precondition(TerminalZoom.percent(steps: preference.wrappedValue) == 60)
        precondition(TerminalZoom.scale(steps: preference.wrappedValue) == 0.6)
        preference.wrappedValue = -3
        let reopened = AppStorage(wrappedValue: TerminalZoom.initialDefaultSteps,
            TerminalZoom.defaultStepsKey, store: defaults)
        precondition(reopened.wrappedValue == -3, "The default must persist across settings instances")
        precondition(TerminalZoom.resolvedSteps(scene: nil, defaultSteps: reopened.wrappedValue) == -3)
        precondition(TerminalZoom.resolvedSteps(scene: -2, defaultSteps: reopened.wrappedValue) == -2,
            "A restored scene keeps its custom zoom, including the previous 80% value")
        preference.wrappedValue = -4
        precondition(TerminalZoom.resolvedSteps(scene: nil, defaultSteps: preference.wrappedValue) == -4)
        precondition(TerminalZoom.resolvedSteps(scene: nil, defaultSteps: -100) == -9)
        precondition(TerminalZoom.resolvedSteps(scene: 100, defaultSteps: -4) == 10)
        print("PASS: 60% initial zoom, persistent default changes, scene overrides, and zoom bounds")
    }
}
