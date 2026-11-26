import SwiftUI

@main
struct ConnectionLabApp: App {
    @State private var lab: LabModel
    @State private var terminalHistory = FixtureTerminalHistory()

    init() {
        let model = LabModel(scenario: Self.argument("--scenario").flatMap(LabScenario.init(rawValue:)) ?? .discovering)
        if let surface = Self.argument("--surface").flatMap(LabSurface.init(rawValue:)) {
            model.navigate(surface)
        }
        _lab = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup("Launcher", id: "launcher") {
            LauncherView(showControlsOnLaunch: ProcessInfo.processInfo.arguments.contains("--controls"))
                .environment(lab)
        }
        .defaultSize(width: 910, height: 580)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        WindowGroup("Terminal", id: "fixture-terminal", for: FixtureTerminal.self) { terminal in
            if let value = terminal.wrappedValue {
                FixtureTerminalView(terminal: value)
                    .environment(terminalHistory)
            }
        }
        .defaultSize(width: 820, height: 500)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        Window("Connection Lab Controls", id: "controls") {
            ScenarioControls()
                .environment(lab)
        }
        .defaultSize(width: 530, height: 700)
        .defaultLaunchBehavior(.suppressed)

        Window("Ask SlopZooka", id: "ask") {
            VoicePermissionView()
                .environment(lab)
        }
        .defaultSize(width: 520, height: 560)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
