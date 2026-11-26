import SwiftUI

struct FixtureEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let badge: String
    let directory: String
    let branch: String

    static let repos = [
        Self(id: "repo-slopzooka", title: "sragss/slopzooka", detail: "Spatial coding for Apple Vision Pro", badge: "main", directory: "slopzooka", branch: "main"),
        Self(id: "repo-orbit", title: "studio/orbit-web", detail: "Marketing site and customer dashboard", badge: "main", directory: "orbit-web", branch: "main"),
        Self(id: "repo-interface", title: "studio/interface-kit", detail: "Shared UI components and documentation", badge: "main", directory: "interface-kit", branch: "main")
    ]

    struct WorktreeGroup: Identifiable {
        let repository: String
        let entries: [FixtureEntry]
        var id: String { repository }
    }

    static let worktreeGroups: [WorktreeGroup] = [
        .init(repository: "sragss/slopzooka", entries: [
            Self(id: "tree-connection", title: "Connection Lab", detail: "ux/connection-lab", badge: "Codex running", directory: "slopzooka/connection-lab", branch: "ux/connection-lab"),
            Self(id: "tree-reconnect", title: "Reconnect state", detail: "fix/reconnect-state", badge: "Shell ready", directory: "slopzooka/reconnect-state", branch: "fix/reconnect-state")
        ]),
        .init(repository: "studio/orbit-web", entries: [
            Self(id: "tree-dashboard", title: "Dashboard filters", detail: "feat/dashboard-filters", badge: "Shell ready", directory: "orbit-web/dashboard-filters", branch: "feat/dashboard-filters")
        ]),
        .init(repository: "studio/interface-kit", entries: [
            Self(id: "tree-tokens", title: "Color tokens", detail: "feat/color-tokens", badge: "Shell ready", directory: "interface-kit/color-tokens", branch: "feat/color-tokens")
        ])
    ]

    static let threads = [
        Self(id: "thread-connection", title: "Simplify the Vision Pro connection flow", detail: "sragss/slopzooka · ux/connection-lab", badge: "Just now", directory: "slopzooka/connection-lab", branch: "ux/connection-lab"),
        Self(id: "thread-reconnect", title: "Review reconnect and cancel behavior", detail: "sragss/slopzooka · fix/reconnect-state", badge: "24 min ago", directory: "slopzooka/reconnect-state", branch: "fix/reconnect-state"),
        Self(id: "thread-tokens", title: "Document semantic color tokens", detail: "studio/interface-kit · feat/color-tokens", badge: "Yesterday", directory: "interface-kit/color-tokens", branch: "feat/color-tokens")
    ]
}

struct FixtureTerminal: Codable, Hashable {
    let mac: String
    let entryID: String
    let title: String
    let directory: String
    let branch: String
    let tool: String
}

@MainActor
@Observable
final class FixtureTerminalHistory {
    private var transcripts: [FixtureTerminal: [String]] = [:]

    func transcript(for terminal: FixtureTerminal) -> [String] {
        transcripts[terminal] ?? [
            "\(terminal.tool) · \(terminal.mac)",
            "~/workspaces/\(terminal.directory)",
            "",
            "Try git status, pwd, ls, help, or clear."
        ]
    }

    func submit(_ input: String, in terminal: FixtureTerminal) {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if command == "clear" {
            transcripts[terminal] = []
            return
        }
        let output: String
        switch command {
        case "pwd": output = "/Users/demo/workspaces/\(terminal.directory)"
        case "ls": output = "README.md  apps  docs  packages"
        case "git status": output = "On branch \(terminal.branch)\nWorking tree clean."
        case "help": output = "Available fixture commands: git status, pwd, ls, clear, help"
        default: output = "Input recorded."
        }
        transcripts[terminal] = Array((transcript(for: terminal) + ["❯ \(command)", output]).suffix(200))
    }
}

struct FixtureTerminalView: View {
    let terminal: FixtureTerminal
    @Environment(FixtureTerminalHistory.self) private var history
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(terminal.title, systemImage: "terminal").font(.headline)
                Spacer()
                Text("Simulated terminal").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(20)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(history.transcript(for: terminal).joined(separator: "\n"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .defaultScrollAnchor(.bottom)
                Divider()
                HStack(spacing: 12) {
                    Text("❯").foregroundStyle(.green).accessibilityHidden(true)
                    TextField("Type a command", text: $input)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($inputFocused)
                        .onSubmit(submit)
                    Button("Run", action: submit)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .font(.system(.body, design: .monospaced))
            .padding(.bottom, 6)
            .background(.black.opacity(0.72))
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
        .frame(minWidth: 620, minHeight: 420)
    }

    private func submit() {
        history.submit(input, in: terminal)
        input = ""
        inputFocused = true
    }
}
