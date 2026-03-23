import Foundation

struct CompanionHealthResponse: Decodable {
    let ok: Bool
    let name: String
    let version: String
    let hostname: String
    let localHostName: String
    let controlOrigin: String
    let cwd: String
    let logFilePath: String
}

struct RecentReposResponse: Decodable {
    let viewerLogin: String
    let repos: [RecentRepoSummary]
}

struct RecentRepoSummary: Decodable, Identifiable, Hashable {
    struct OwnerSummary: Decodable, Hashable {
        let login: String
        let name: String?
        let avatarUrl: String
    }

    let name: String
    let nameWithOwner: String
    let url: String
    let sshUrl: String
    let pushedAt: Date
    let isPrivate: Bool
    let defaultBranch: String?
    let owner: OwnerSummary

    var id: String { nameWithOwner }
}

struct LaunchWorkspaceRequest: Encodable {
    let nameWithOwner: String
    let profile: String?
}

struct LaunchWorkspaceResponse: Decodable {
    let localCheckoutPath: String
    let worktreePath: String
    let branchName: String
    let baseRef: String
    let launchURL: String
    let wasCloned: Bool
    let clusterId: String
    let repo: RecentRepoSummary
}

struct APIErrorResponse: Decodable {
    let error: String
}

struct TerminalWindowPayload: Codable, Hashable {
    let id: String
    let title: String
    let urlString: String

    var url: URL? {
        URL(string: urlString)
    }
}

enum TerminalLoadState: Equatable {
    case idle
    case loading(String)
    case loaded
    case failed(String)
}

enum HealthState {
    case idle
    case checking
    case success(CompanionHealthResponse)
    case failure(String)
}

enum LaunchTarget: String, CaseIterable, Identifiable, Codable, Hashable {
    case codex
    case claude
    case opencode
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .opencode:
            return "OpenCode"
        case .terminal:
            return "Terminal"
        }
    }

    var queryValue: String? {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .opencode:
            return "opencode"
        case .terminal:
            return nil
        }
    }

    var subtitle: String {
        switch self {
        case .codex:
            return "Launch Codex in a fresh worktree."
        case .claude:
            return "Launch Claude Code in a fresh worktree."
        case .opencode:
            return "Launch OpenCode in a fresh worktree."
        case .terminal:
            return "Launch a raw shell in a fresh worktree."
        }
    }
}
