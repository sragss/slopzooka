import SwiftUI

@main
struct TerminalLabApp: App {
    @State private var lab: LabModel

    init() {
        let lab = LabModel()
        let arguments = ProcessInfo.processInfo.arguments
        lab.arrangement = Self.argument("--arrangement", in: arguments).flatMap { Arrangement(rawValue: $0) } ?? lab.arrangement
        lab.dictation = Self.argument("--dictation", in: arguments).flatMap { DictationTreatment(rawValue: $0) } ?? .hold
        lab.size = Self.argument("--size", in: arguments).flatMap { WindowSize(rawValue: $0) } ?? .standard
        let session = Self.argument("--session", in: arguments).flatMap { SessionState(rawValue: $0) }
        if let session { lab.selectSession(session) }
        _lab = State(initialValue: lab)
    }

    var body: some Scene {
        Window("Terminal", id: "terminal") {
            LabTerminalWindow()
                .environment(lab)
                .environmentObject(lab.voice)
        }
        .defaultSize(width: 1280, height: 832)
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        Window("Terminal Lab Controls", id: "controls") {
            LabControls()
                .environment(lab)
                .environmentObject(lab.voice)
        }
        .defaultSize(width: 535, height: 760)
        .defaultWindowPlacement { _, context in
            if let terminal = context.windows.first(where: { $0.id == "terminal" }) {
                return WindowPlacement(.trailing(terminal))
            }
            return WindowPlacement()
        }
        .defaultLaunchBehavior(.suppressed)

        Window("SlopZooka", id: "launcher") {
            LabDestination(kind: .launcher)
                .environment(lab)
        }
        .defaultSize(width: 460, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Window("Ask SlopZooka", id: "ask") {
            LabDestination(kind: .coordinator)
                .environment(lab)
                .environmentObject(lab.voice)
        }
        .defaultSize(width: 520, height: 460)
        .defaultLaunchBehavior(.suppressed)

        Window("Preview", id: "preview") {
            FixturePreview(title: lab.previewTitle)
        }
        .defaultSize(width: 740, height: 500)
        .defaultLaunchBehavior(.suppressed)
    }

    private static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct LabControls: View {
    @Environment(LabModel.self) private var lab
    @EnvironmentObject private var voice: TerminalVoiceController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var lab = lab
        NavigationStack {
            Form {
                Section("Experiment") {
                    Picker("Controls", selection: $lab.arrangement) {
                        ForEach(Arrangement.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text(lab.arrangement.summary).font(.footnote).foregroundStyle(.secondary)
                    Picker("Dictation", selection: Binding(get: { lab.dictation }, set: { lab.selectDictation($0) })) {
                        ForEach(DictationTreatment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Window size", selection: $lab.size) {
                        ForEach(WindowSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Scenario") {
                    Picker("Terminal", selection: Binding(get: { lab.session }, set: { lab.selectSession($0) })) {
                        ForEach(SessionState.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frontend catalog", selection: $lab.frontends) {
                        ForEach(FrontendFixture.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Unread notification", isOn: $lab.unread)
                    Toggle("Show Session Details", isOn: Binding(get: { lab.showDetails }, set: {
                        lab.showDetails = $0
                        lab.detailsExpanded = $0
                    }))
                    Menu("Stage voice") {
                        ForEach(VoiceScenario.allCases) { scenario in
                            Button(scenario.rawValue) {
                                if !lab.terminalVisible { showTerminal() }
                                lab.stageVoice(scenario)
                            }
                        }
                    }
                    if lab.dictation == .hold {
                        Button("Start simulated hold") { voice.beginTerminalHold(LabModel.terminalID) }
                            .disabled(!lab.session.acceptsControls || voice.heldTargetID != nil)
                        Button("Release simulated hold") { voice.endTerminalHold(LabModel.terminalID) }
                            .disabled(voice.targetID != LabModel.terminalID || voice.sendDeadline != nil)
                    }
                }
                Section("Fixture activity") {
                    LabeledContent("Last action", value: lab.lastAction)
                    Button("Show Terminal", systemImage: "terminal", action: showTerminal)
                    Button("Reset Scenario", systemImage: "arrow.counterclockwise") { lab.reset() }
                }
            }
            .navigationTitle("Terminal Lab Controls")
        }
    }

    private func showTerminal() {
        lab.terminalVisible = true
        openWindow(id: "terminal")
    }

}

struct LabDestination: View {
    enum Kind { case launcher, coordinator }
    let kind: Kind
    @Environment(LabModel.self) private var lab
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        switch kind {
        case .launcher:
            VStack(alignment: .leading, spacing: 14) {
                Text("SlopZooka").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Terminals").font(.headline)
                Button(lab.payload.title, systemImage: "terminal") {
                    lab.terminalVisible = true
                    openWindow(id: "terminal")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Button("Lab Controls", systemImage: "slider.horizontal.3") { openWindow(id: "controls") }
            }
            .padding(24)
        case .coordinator:
            VStack {
                Text("Ask SlopZooka").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Hold to ask about this terminal.").foregroundStyle(.secondary)
                Spacer()
                TerminalVoiceButton(id: "coordinator-fixture", isAvailable: lab.session.acceptsControls, mode: .coordinator)
                Button("Close") { dismissWindow(id: "ask") }
            }
            .padding(24)
            .modifier(TerminalVoiceOverlay(id: "coordinator-fixture", isAvailable: lab.session.acceptsControls,
                                           canRename: false, mode: .coordinator))
        }
    }
}
