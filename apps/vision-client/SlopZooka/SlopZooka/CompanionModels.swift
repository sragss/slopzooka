import Foundation

struct CompanionHealthResponse: Decodable, Equatable {
    let hostId: String
    let paired: Bool
    let protocolVersion: Int
    let controlOrigin: String
    let logFilePath: String
}

struct RecentReposResponse: Decodable {
    let repos: [RecentRepoSummary]
}

struct AvailableOwnersResponse: Decodable {
    let owners: [RepoOwnerSummary]
}

struct RepoOwnerSummary: Decodable, Identifiable {
    let login: String
    var id: String { login }
}

struct RecentRepoSummary: Decodable, Identifiable {
    struct OwnerSummary: Decodable {
        let avatarUrl: String
    }

    let nameWithOwner: String
    let isPrivate: Bool
    let defaultBranch: String?
    let owner: OwnerSummary

    var id: String { nameWithOwner }
}

struct LaunchWorkspaceResponse: Decodable {
    let branchName: String
    let workspaceId: String
    let repo: RecentRepoSummary
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

struct WorkspaceSummary: Decodable, Identifiable {
    let workspaceId: String
    let repo: RecentRepoSummary
    let branchName: String
    var name: String? = nil
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

// Resolved view data is deliberately not Codable. Persist WindowRecord instead.
struct TerminalWindowPayload {
    let id: String
    let workspaceId: String
    let title: String
    let urlString: String
    var projectName: String? = nil
    var workspaceName: String? = nil
    var displayTitle: String { [projectName, workspaceName, title].compactMap { $0 }.joined(separator: " / ") }

    var url: URL? {
        URL(string: urlString)
    }
}

struct FrontendSummary: Decodable, Identifiable {
    let id: String
    let hostname: String
    let url: String
    let transport: String
    let title: String?
    let source: String?
    let status: String?
    let category: String?
    let project: String?
    let workspaceId: String?
    let workspaceVisible: Bool?
    var displayTitle: String { title ?? hostname }
    var isService: Bool { category == "service" }
}
struct FrontendCatalog: Decodable {
    let frontends: [FrontendSummary]
    let warning: String?

    func visibleFrontends(workspaceID: String?) -> [FrontendSummary] {
        frontends.filter { workspaceID == nil || ($0.workspaceId == workspaceID && $0.workspaceVisible != false && !$0.isService) }
    }
}
struct OpenFrontendResponse: Decodable {
    let frontend: FrontendSummary
    let exposedPort: Int?
    let accessToken: String?
    let gatewayScheme: String?
    let certificateAuthority: String?
}
struct PreviewWindowPayload {
    let id: String
    let title: String
    let urlString: String
    var certificateAuthority: String? = nil
    var stream: ProbeStreamDescriptor? = nil
    var url: URL? { URL(string: urlString) }
}

enum TerminalLoadState: Equatable {
    case ended(String)
    case idle
    case loading(String)
    case disconnected
    case loaded
    case failed(String)
}

enum HealthState {
    case reconnecting(String)
    case idle
    case checking
    case success
    case failure(String)

    var connectionError: String? {
        switch self {
        case .failure(let message), .reconnecting(let message): return message
        default: return nil
        }
    }
    var isReconnecting: Bool { if case .reconnecting = self { return true }; return false }
}

struct DiscoveredCompanion: Identifiable, Hashable {
    let id: String
    let name: String
    let candidateHosts: [String]
    var host: String { candidateHosts[0] }
}

enum LaunchTarget: String, CaseIterable, Identifiable, Hashable {
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

    var queryValue: String? { self == .terminal ? nil : rawValue }
}

enum CatalogState<Value> {
    case idle
    case loading(UUID)
    case loaded(Value)
    case failure(String)

    var value: Value? { if case .loaded(let value) = self { return value }; return nil }
    var requestID: UUID? { if case .loading(let id) = self { return id }; return nil }
}

struct CompanionError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

struct HostSession: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let title: String
    let cwd: String
    var name: String? = nil
    var projectName: String? = nil
    var workspaceName: String? = nil
}
struct HostSessionsResponse: Decodable {
    let sessions: [HostSession]
    var companionInstanceId: String? = nil
    var surfaceProbe: Bool? = nil
}
struct CreatedSessionResponse: Decodable { let session: HostSession }
struct APIAcknowledgement: Decodable { let ok: Bool }

// Ephemeral, opt-in live experiment. Never encoded into WindowRecord.
struct ProbeStreamDescriptor: Codable, Equatable {
    let host: String
    let port: Int
    let token: String
    let fingerprint: String
    let target: String
}
struct ProbeSurfaceResponse: Decodable {
    let id: String
    let title: String
    let workspaceID: String
    let deviceID: String
    let stream: ProbeStreamDescriptor
}
struct ProbePresentationCommand: Codable, Equatable {
    let id: String
    let action: String
    let surfaceID: String
}
struct ProbePresentationReceipt: Codable {
    let id: String
    var error: String? = nil
}
struct ProbePresentationPresence: Encodable {
    let id: String
    let surfaceID: String
    let presented: Bool
    let receiver: String
}
struct ProbePresentationBatch: Decodable {
    let instanceID: String
    let commands: [ProbePresentationCommand]
}
