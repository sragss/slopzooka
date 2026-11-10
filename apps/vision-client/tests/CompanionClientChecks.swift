import Foundation

@main
struct CompanionClientChecks {
    @MainActor
    static func main() async throws {
        defer { CompanionTestPreferences.clean() }
        let base = URL(string: "http://fixture.invalid:7777/terminal?sessionId=old")!
        var requests: [URLRequest] = []
        let api = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials()) { request in
            requests.append(request)
            switch request.url!.path {
            case "/api/workspaces/workspace/sessions":
                return try json(["session": ["id": "session", "workspaceId": "workspace", "title": "Shell",
                    "cwd": "/fixture", "status": "running"]], for: request)
            case "/api/sessions/session/input":
                return try json(["ok": true], for: request)
            case "/api/repos/recent":
                return try json(["viewerLogin": "test", "repos": [
                    ["name": "fixture", "nameWithOwner": "test/fixture", "url": "", "sshUrl": "", "isPrivate": true,
                        "pushedAt": "2026-01-01T00:00:00.123Z", "owner": ["login": "test", "avatarUrl": ""]],
                    ["nameWithOwner": "test/other", "isPrivate": true, "owner": ["avatarUrl": ""]]
                ]], for: request)
            case "/api/repos/create-and-launch", "/api/workspaces/launch":
                return try json(["error": "Unavailable"], for: request, status: 503)
            case "/health":
                return try json(["error": "Pair again"], for: request, status: 401)
            case "/api/pair/display":
                return try json(["ok": true], for: request)
            default:
                preconditionFailure("Unexpected request")
            }
        }
        try api.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: true)
        let session = try await api.launchSession(hostID: "fixture", workspaceID: "workspace", sessionID: "session", profile: nil)
        precondition(session.session.id == "session")
        let launch = requests.last!
        let body = try JSONSerialization.jsonObject(with: launch.httpBody!) as! [String: Any]
        precondition(launch.url!.absoluteString == "http://fixture.invalid:7777/api/workspaces/workspace/sessions")
        precondition(launch.httpMethod == "POST" && launch.timeoutInterval == 20)
        precondition(body["sessionId"] as? String == "session" && body["profile"] is NSNull,
            "The gateway's session ID and explicit default profile must reach the Mac unchanged")
        precondition(launch.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(UUID(uuidString: launch.value(forHTTPHeaderField: "X-SlopZooka-Client-ID")!) != nil)

        try await api.submitInput(hostID: "fixture", sessionID: "session", commandID: "command", text: "echo 'hello'\n")
        let input = requests.last!.httpBody!
        try await api.submitInput(hostID: "fixture", sessionID: "session", commandID: "command", text: "echo 'hello'\n")
        precondition(input == requests.last!.httpBody!, "Retrying a command must preserve its exact body")
        let inputBody = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        precondition(inputBody["commandId"] as? String == "command" && inputBody["sendReturn"] as? Bool == true)
        precondition(inputBody["text"] as? String == "echo 'hello'\n")
        precondition(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-SlopZooka-Client-ID") == launch.value(forHTTPHeaderField: "X-SlopZooka-Client-ID")
        }, "Layout, control, and input operations must share the same client identity")

        let repositories = try await api.repositories(hostID: "fixture")
        precondition(repositories.repos.map(\.id) == ["test/fixture", "test/other"],
            "The native client only requires displayed fields and preserves the Mac's catalog order")
        precondition(requests.last!.url!.query == "limit=30")
        do {
            _ = try await api.createRepository(hostID: "fixture", owner: "test", name: "new", isPrivate: true, profile: nil)
            preconditionFailure("Expected service failure")
        } catch let error as CompanionError {
            precondition(error.statusCode == 503)
        }
        let creation = requests.last!
        precondition(creation.timeoutInterval == 300, "Repository operations retain their longer timeout")
        let creationBody = try JSONSerialization.jsonObject(with: creation.httpBody!) as! [String: Any]
        precondition(creationBody["owner"] as? String == "test" && creationBody["repoName"] as? String == "new")
        precondition(creationBody["visibility"] as? String == "private" && creationBody["profile"] == nil)
        precondition(requests.filter { $0.url!.path == "/api/repos/create-and-launch" }.count == 1,
            "The client must not automatically repeat mutations")
        for profile: String? in [nil, "codex"] {
            _ = try? await api.launchWorkspace(hostID: "fixture", nameWithOwner: "test/fixture", profile: profile)
            let payload = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
            precondition(payload["nameWithOwner"] as? String == "test/fixture" && payload["profile"] as? String == profile)
            if profile == nil { precondition(payload["profile"] == nil, "Default launch profile is omitted rather than encoded as null") }
        }
        api.host = base.absoluteString
        let connected = await api.connect()
        precondition(!connected)
        guard let message = api.healthState.connectionError else { preconditionFailure("Expected pairing failure") }
        precondition(message.contains("GET /health — HTTP 401: Pair again"))
        precondition(requests.last!.timeoutInterval == 4)
        try api.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: false)
        await api.showConnectionCode()
        precondition(requests.last!.httpMethod == "POST" && requests.last!.timeoutInterval == 4)

        let disconnected = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials()) { _ in throw URLError(.networkConnectionLost) }
        try disconnected.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: true)
        do {
            try await disconnected.endSession(hostID: "fixture", id: "session")
            preconditionFailure("Expected transport failure")
        } catch let error as URLError { precondition(error.code == .networkConnectionLost) }
        try await sessionRefreshChecks()
        try await routeChecks()
        try await credentialChecks()
        try await catalogChecks()
        try await pairingChecks()
        try await frontendSharingChecks()
        print("PASS: production companion client preserves request identity, command bodies, minimal responses, timeouts, HTTP status, and transport errors")
    }
    @MainActor
    static func sessionRefreshChecks() async throws {
        var release: CheckedContinuation<Void, Never>?
        var delay = true
        var snapshots: [(String, String)] = []
        let first = URL(string: "http://first.invalid:7777")!
        let second = URL(string: "http://second.invalid:7777")!
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials()) { request in
            let name = delay ? "old" : "new"
            if delay { delay = false; await withCheckedContinuation { release = $0 } }
            return try json(["sessions": [["id": "session", "workspaceId": "workspace", "title": "codex", "cwd": "/project", "workspaceName": name]]], for: request)
        }
        try client.accept(fixtureHealth("first", endpoint: first), endpoint: first, authenticated: true)
        client.onSessionSnapshot = { snapshot, host in snapshots.append((host.id, snapshot.sessions[0].workspaceName!)) }
        let stale = Task { await client.refreshSessions() }
        while release == nil { await Task.yield() }
        await client.refreshSessions(force: true)
        release!.resume()
        await stale.value
        precondition(snapshots.map { $0.1 } == ["new"], "A pre-rename read cannot overwrite refreshed workspace names")
        try client.accept(fixtureHealth("second", endpoint: second), endpoint: second, authenticated: true)
        await client.refreshSessions(hostID: "first", force: true)
        precondition(snapshots.last!.0 == "first" && client.current?.id == "second", "Old-host windows refresh their own names without changing the selected Mac")
        print("PASS: rename refresh rejects late snapshots and updates old-host windows independently of Mac selection")
    }

    @MainActor
    static func routeChecks() async throws {
        let local = URL(string: "http://local.invalid:7777")!, remote = URL(string: "https://remote.invalid")!
        let credentials = testCredentials()
        try credentials.pair(local, hostID: "mac", token: "secret")
        try credentials.pair(remote, hostID: "mac", token: "secret")
        var offline = false
        var release: CheckedContinuation<Void, Never>?
        var delayNext = false
        var observed: [URL] = []
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            observed.append(request.url!)
            if offline { throw URLError(.networkConnectionLost) }
            if request.url!.path == "/health" { return try json(healthJSON("mac", endpoint: origin(request.url!)), for: request) }
            if request.url!.path == "/api/sessions" {
                if delayNext { delayNext = false; await withCheckedContinuation { release = $0 } }
                return try json(["sessions": []], for: request)
            }
            if request.url!.path == "/api/frontends" { return try json(["frontends": []], for: request) }
            return try json(["ok": true], for: request)
        }
        await client.select(local.absoluteString)
        precondition(client.isReady && client.current?.id == "mac")
        let previous = client.current!
        delayNext = true
        let late = Task { try await client.sessions(hostID: "mac") }
        while release == nil { await Task.yield() }
        await client.select(remote.absoluteString)
        precondition(client.current?.id == previous.id && client.current != previous)
        release!.resume()
        do { _ = try await late.value; preconditionFailure("Superseded route reply must be rejected") }
        catch let error as URLError { precondition(error.code == .cancelled) }
        try await client.endSession(hostID: "mac", id: "session")
        precondition(observed.last!.host == "remote.invalid")
        offline = true
        await client.refreshSessions()
        precondition(!client.isReady && client.healthState.isReconnecting)
        offline = false
        await client.refreshSessions()
        precondition(client.isReady, "A successful refresh restores connected state")

        // A stalled refresh on the old route cannot block recovery on the new one.
        release = nil
        delayNext = true
        let oldRefresh = Task { await client.refreshSessions() }
        while release == nil { await Task.yield() }
        var snapshot: ConnectedHost?
        client.onSessionSnapshot = { _, host in snapshot = host }
        await client.select(local.absoluteString)
        precondition(snapshot == client.current, "New-route refresh must run while the old request is pending")
        release!.resume()
        await oldRefresh.value
        precondition(snapshot == client.current && client.isReady)

        // A route that changes away and back is still a different connection attempt.
        release = nil
        delayNext = true
        let oldAttempt = Task { try await client.sessions(hostID: "mac") }
        while release == nil { await Task.yield() }
        try client.accept(fixtureHealth("mac", endpoint: remote), endpoint: remote, authenticated: true)
        try client.accept(fixtureHealth("mac", endpoint: local), endpoint: local, authenticated: true)
        release!.resume()
        do { _ = try await oldAttempt.value; preconditionFailure("Old connection generation must be rejected") }
        catch let error as URLError { precondition(error.code == .cancelled) }
        precondition(client.isReady)
        print("PASS: host IDs resolve current routes, superseded generations are rejected, and connection loss/recovery updates readiness")
    }

    @MainActor
    static func credentialChecks() async throws {
        let local = URL(string: "http://Legacy.invalid:7777")!, remote = URL(string: "https://remote.invalid")!
        var values = ["http://Legacy.invalid:7777": "legacy-token"]
        let credentials = CompanionCredentials(read: { values[$0] }, write: { values[$0] = $1 })
        let legacy = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer legacy-token")
            switch request.url!.path {
            case "/health": return try json(healthJSON("mac", endpoint: local), for: request)
            case "/api/sessions": return try json(["sessions": []], for: request)
            default: return try json(["frontends": []], for: request)
            }
        }
        await legacy.select(local.absoluteString)
        precondition(legacy.isReady && !legacy.needsPairing)
        precondition(values["host:mac"] == "legacy-token" && credentials.token(for: local) == "legacy-token")
        precondition(credentials.token(for: remote) == nil, "An unknown route cannot inherit a host credential")
        var authorization: String?
        let untrusted = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return try json(healthJSON("mac", endpoint: remote, paired: true), for: request)
        }
        await untrusted.select(remote.absoluteString)
        precondition(authorization == nil && untrusted.needsPairing && !untrusted.isReady,
            "A claimed host ID and paired flag do not establish route trust")
        do { _ = try await untrusted.sessions(hostID: "mac"); preconditionFailure("Unpaired route must reject control operations") }
        catch let error as CompanionError { precondition(error.statusCode == 401) }
        try credentials.pair(remote, hostID: "mac", token: "new-token")
        precondition(credentials.token(for: local) == "new-token" && credentials.token(for: remote) == "new-token")
        do { try credentials.migrate(remote, hostID: "impostor"); preconditionFailure("Route identity mismatch must be rejected") }
        catch {}
        precondition(values["route:https://remote.invalid:443"] == "mac")
        print("PASS: legacy pairing migrates to host identity, explicit routes share trust, and claimed identities cannot obtain credentials")
    }

    @MainActor
    static func catalogChecks() async throws {
        let first = URL(string: "http://first.invalid")!, second = URL(string: "http://second.invalid")!
        var catalogStatus = 200
        var sessionStatus = 200
        var catalogRequests = 0
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials()) { request in
            if request.url!.path == "/api/sessions" {
                return try json(sessionStatus == 200 ? ["sessions": []] : ["error": "Pair again"], for: request, status: sessionStatus)
            }
            catalogRequests += 1
            if catalogStatus != 200 { return try json(["error": "Catalog unavailable"], for: request, status: catalogStatus) }
            return try json(["frontends": [["id": "first-app", "hostname": "localhost", "url": "http://localhost:3000", "transport": "gateway"]]], for: request)
        }
        try client.accept(fixtureHealth("first", endpoint: first), endpoint: first, authenticated: true)
        await client.refreshFrontends(hostID: "first")
        precondition(client.frontends(for: "first").frontends.map(\.id) == ["first-app"])
        catalogStatus = 503
        await client.refreshFrontends(hostID: "first")
        precondition(!client.frontends(for: "first").frontends.isEmpty && client.frontends(for: "first").warning != nil, "A refresh failure preserves this Mac's cached catalog")
        try client.accept(fixtureHealth("second", endpoint: second), endpoint: second, authenticated: true)
        precondition(client.frontends(for: "second").frontends.isEmpty && client.frontends(for: "second").warning == nil, "Switching Macs clears cached content and its warning immediately")
        await client.refreshFrontends(hostID: "second")
        precondition(client.isReady && client.frontends(for: "second").frontends.isEmpty && client.frontends(for: "second").warning != nil,
            "The new Mac's catalog failure must never display the previous Mac's apps")
        sessionStatus = 401
        let before = catalogRequests
        await client.refreshSessions()
        await client.refreshFrontends(hostID: "second")
        precondition(client.needsPairing && !client.isReady && catalogRequests == before,
            "Central request handling invalidates authentication and stops further refresh requests")
        print("PASS: catalogs stay scoped to their Mac, failed switches cannot show old apps, and authentication failure stops refresh")
    }

    @MainActor
    static func frontendSharingChecks() async throws {
        let first = URL(string: "http://first.invalid")!, second = URL(string: "http://second.invalid")!
        let replacement = URL(string: "http://replacement.invalid")!
        var apps = ["first.invalid": ["old"], "second.invalid": ["other"], "replacement.invalid": ["replacement"]]
        var reads: [String: Int] = [:]
        var delayNext = true
        var releaseCatalog: CheckedContinuation<Void, Never>?
        var releaseSessions: CheckedContinuation<Void, Never>?
        var oldCatalogFinished = false
        func app(_ id: String) -> [String: Any] {
            ["id": id, "hostname": "localhost", "url": "http://localhost:3000", "transport": "gateway"]
        }
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: testCredentials()) { request in
            let host = request.url!.host!, path = request.url!.path
            if path == "/api/sessions" {
                await withCheckedContinuation { releaseSessions = $0 }
                return try json(["sessions": []], for: request)
            }
            if request.httpMethod == "POST" {
                apps[host]!.append("new")
                return try json(["frontend": app("new")], for: request)
            }
            if request.httpMethod == "DELETE" {
                apps[host]!.removeAll { $0 == "new" }
                return try json(["ok": true], for: request)
            }
            precondition(path == "/api/frontends")
            reads[host, default: 0] += 1
            let snapshot = apps[host]!
            if host == first.host, delayNext {
                delayNext = false
                await withCheckedContinuation { releaseCatalog = $0 }
                oldCatalogFinished = true
            }
            return try json(["frontends": snapshot.map(app)], for: request)
        }
        try client.accept(fixtureHealth("first", endpoint: first), endpoint: first, authenticated: true)
        try client.accept(fixtureHealth("second", endpoint: second), endpoint: second, authenticated: true)
        client.start() // Exercise the real per-Mac poll lifetime, independently of any view.
        while releaseCatalog == nil || releaseSessions == nil || client.frontends(for: "second").frontends.isEmpty { await Task.yield() }
        await client.refreshFrontends(hostID: "first")
        await client.refreshFrontends(hostID: "first")
        precondition(reads[first.host!] == 1, "All views of a Mac must share its pending catalog read")
        precondition(client.frontends(for: "second").frontends.map(\.id) == ["other"],
            "A stalled Mac or session request cannot block another Mac's catalog")
        try await client.addFrontend(hostID: "first", url: "http://localhost:3000")
        precondition(client.frontends(for: "first").frontends.map(\.id) == ["old", "new"])
        releaseCatalog!.resume()
        while !oldCatalogFinished { await Task.yield() }
        precondition(client.frontends(for: "first").frontends.map(\.id) == ["old", "new"],
            "A catalog read started before an edit cannot replace the edit's refreshed snapshot")
        try await client.removeFrontend(hostID: "first", id: "new")
        precondition(client.frontends(for: "first").frontends.map(\.id) == ["old"])
        precondition(client.frontends(for: "second").frontends.map(\.id) == ["other"])

        delayNext = true
        releaseCatalog = nil
        let oldRoute = Task { await client.refreshFrontends(hostID: "first") }
        while releaseCatalog == nil { await Task.yield() }
        try client.accept(fixtureHealth("first", endpoint: replacement), endpoint: replacement, authenticated: true)
        while client.frontends(for: "first").frontends.isEmpty { await Task.yield() }
        releaseCatalog!.resume()
        await oldRoute.value
        precondition(client.frontends(for: "first").frontends.map(\.id) == ["replacement"],
            "A new route refreshes immediately and rejects the old route's pending catalog")
        releaseSessions!.resume()
        print("PASS: one shared catalog per Mac coalesces reads, stays independent, refreshes after edits, and rejects late routes")
    }

    @MainActor
    static func pairingChecks() async throws {
        let first = URL(string: "http://first.invalid")!, second = URL(string: "http://second.invalid")!
        var values: [String: String] = [:]
        let credentials = CompanionCredentials(read: { values[$0] }, write: { values[$0] = $1 })
        try credentials.pair(first, hostID: "mac", token: "original-token")
        try credentials.pair(second, hostID: "mac", token: "original-token")
        var requests: [URLRequest] = []
        var sessionStatus = 200
        var delayPair = false
        var release: CheckedContinuation<Void, Never>?
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            requests.append(request)
            if request.url!.host == "offline.invalid" { throw URLError(.cannotConnectToHost) }
            switch request.url!.path {
            case "/health": return try json(healthJSON("mac", endpoint: origin(request.url!)), for: request)
            case "/api/sessions": return try json(sessionStatus == 200 ? ["sessions": []] : ["error": "Pair again"], for: request, status: sessionStatus)
            case "/api/frontends": return try json(["frontends": []], for: request)
            case "/api/pair":
                if delayPair { await withCheckedContinuation { release = $0 } }
                return try json(["hostId": "mac", "token": delayPair ? "stale-token" : "new-token"], for: request)
            case "/api/pair/display": return try json(["ok": true], for: request)
            default: preconditionFailure("Unexpected request")
            }
        }
        await client.select(first.absoluteString)
        await client.select("http://offline.invalid")
        sessionStatus = 401
        await client.refreshSessions()
        precondition(client.needsPairing && client.current?.id == "mac")
        await client.showConnectionCode()
        precondition(requests.last!.url!.host == first.host,
            "Displaying a pairing code must use the accepted Mac, even after a failed address change")
        client.pairingCode = "123456"
        sessionStatus = 200
        await client.pair()
        precondition(client.isReady && credentials.token(for: first) == "new-token")
        precondition(requests.first(where: { $0.url!.path == "/api/pair" })!.url!.host == first.host,
            "Pairing and its authenticated reconnect must stay on the accepted route")

        // A successful old reply must not overwrite credentials shared by the new route.
        sessionStatus = 401
        await client.refreshSessions()
        delayPair = true
        client.pairingCode = "654321"
        let pairing = Task { await client.pair() }
        while release == nil { await Task.yield() }
        sessionStatus = 200
        await client.select(second.absoluteString)
        release!.resume()
        await pairing.value
        let endpoint = try client.endpoint(for: "mac")
        precondition(client.isReady && endpoint == second)
        precondition(credentials.token(for: first) == "new-token" && credentials.token(for: second) == "new-token",
            "A superseded pairing reply must not change credentials or route trust")
        print("PASS: pairing stays on the accepted Mac and superseded successful replies cannot change credentials")
    }

}
