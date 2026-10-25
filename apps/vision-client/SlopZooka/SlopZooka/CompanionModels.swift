import Foundation

struct CompanionHealthResponse: Decodable {
    struct WorkspacePaths: Decodable {
        let slopzookaHome: String
        let workspacesRoot: String
        let reposRoot: String
        let worktreesRoot: String
        let workspaceIndexPath: String
    }

    let ok: Bool
    let hostId: String
    let paired: Bool
    let protocolVersion: Int
    let name: String
    let version: String
    let hostname: String
    let localHostName: String
    let controlOrigin: String
    let bonjourServiceType: String?
    let cwd: String
    let logFilePath: String
    let workspacePaths: WorkspacePaths?
}

struct RecentReposResponse: Decodable {
    let viewerLogin: String
    let repos: [RecentRepoSummary]
}

struct AvailableOwnersResponse: Decodable {
    let viewerLogin: String
    let owners: [RepoOwnerSummary]
}

struct RepoOwnerSummary: Decodable, Identifiable, Hashable {
    let login: String
    let name: String?
    let avatarUrl: String
    let kind: Kind

    enum Kind: String, Decodable {
        case user
        case org
    }

    var id: String { login }

    var badgeTitle: String {
        switch kind {
        case .user:
            return "Personal"
        case .org:
            return "Org"
        }
    }
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
    let wasCloned: Bool
    let workspaceId: String
    let repo: RecentRepoSummary
}

struct CreateRepoAndLaunchRequest: Encodable {
    let owner: String
    let repoName: String
    let visibility: String
    let profile: String?
}

struct RecentWorkspacesResponse: Decodable {
    let workspaces: [WorkspaceSummary]
}

struct ArchiveWorkspaceResponse: Decodable {
    let workspace: WorkspaceSummary
}

struct PruneMissingWorkspacesResponse: Decodable {
    let archivedCount: Int
}

struct ReopenWorkspaceRequest: Encodable {
    let profile: String?
}

struct WorkspaceSummary: Decodable, Identifiable, Hashable {
    let workspaceId: String
    let repo: RecentRepoSummary
    let profile: String?
    let localCheckoutPath: String
    let worktreePath: String
    let branchName: String
    let baseRef: String
    let createdAt: Date
    let updatedAt: Date
    let archivedAt: Date?
    let existsOnDisk: Bool

    var id: String { workspaceId }
}

struct LaunchFeedback: Equatable {
    enum Style {
        case neutral
        case success
        case error
    }

    let message: String
    let style: Style
}

struct APIErrorResponse: Decodable {
    let error: String
}

struct TerminalWindowPayload: Codable, Hashable {
    let id: String
    let workspaceId: String
    let title: String
    let urlString: String

    var url: URL? {
        URL(string: urlString)
    }
}

struct FrontendSummary: Decodable, Hashable, Identifiable {
    let id: String
    let hostname: String
    let url: String
    let transport: String
    let title: String?
    let source: String?
    let status: String?
    var displayTitle: String { title ?? hostname }
}
struct FrontendCatalog: Decodable {
    let frontends: [FrontendSummary]
    let warning: String?
}
struct OpenFrontendResponse: Decodable {
    let frontend: FrontendSummary
    let exposedPort: Int?
    let accessToken: String?
}
struct PreviewWindowPayload: Codable, Hashable {
    let id: String
    let title: String
    let urlString: String
    var url: URL? { URL(string: urlString) }
}

enum TerminalLoadState: Equatable {
    case ended(String)
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

struct DiscoveredCompanion: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let hostname: String
    let port: Int
    let candidateHosts: [String]
}

enum CompanionDiscoveryState: Equatable {
    case idle
    case searching
    case found(count: Int)
    case failed(String)
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
