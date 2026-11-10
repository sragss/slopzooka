import Foundation

func response(_ data: Data, for request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!)
}
func json(_ object: Any, for request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
    response(try JSONSerialization.data(withJSONObject: object), for: request, status: status)
}
func sessionJSON(_ session: HostSession) -> [String: Any] {
    ["id": session.id, "workspaceId": session.workspaceId, "profile": NSNull(),
        "title": session.title, "cwd": session.cwd, "status": "running", "name": session.name as Any? ?? NSNull(),
        "projectName": session.projectName as Any? ?? NSNull(), "workspaceName": session.workspaceName as Any? ?? NSNull()]
}

func origin(_ url: URL) -> URL {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.path = ""
    parts.query = nil
    parts.fragment = nil
    return parts.url!
}

@MainActor
func testCredentials() -> CompanionCredentials {
    var values: [String: String] = [:]
    return CompanionCredentials(read: { values[$0] }, write: { values[$0] = $1 })
}
func fixtureHealth(_ id: String, endpoint: URL, paired: Bool = true, version: Int = 1) -> CompanionHealthResponse {
    CompanionHealthResponse(hostId: id, paired: paired, protocolVersion: version,
        controlOrigin: endpoint.absoluteString, logFilePath: "")
}
func healthJSON(_ id: String, endpoint: URL, paired: Bool = true) -> [String: Any] {
    ["ok": true, "hostId": id, "paired": paired, "protocolVersion": 1, "name": "Fixture", "version": "1",
        "hostname": "fixture", "localHostName": "fixture", "controlOrigin": endpoint.absoluteString,
        "cwd": "/", "logFilePath": ""]
}

@MainActor
enum CompanionTestPreferences {
    static let suite = "CompanionClientChecks.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suite)!
    static func clean() { defaults.removePersistentDomain(forName: suite) }
}
