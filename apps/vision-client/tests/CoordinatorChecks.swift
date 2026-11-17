import Foundation

@main
struct CoordinatorChecks {
    @MainActor
    static func main() async throws {
        defer { CompanionTestPreferences.clean() }
        var requests: [URLRequest] = []
        var release: CheckedContinuation<Void, Never>?
        var blocked = true
        var tokens = ["host:fixture": "fixture-token"]
        let credentials = CompanionCredentials(read: { tokens[$0] }, write: { tokens[$0] = $1 })
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            requests.append(request)
            if request.url!.path == "/api/coordinator", request.httpMethod == "GET", blocked {
                await withCheckedContinuation { release = $0 }
            }
            return try json(["available": true, "status": "completed", "reply": request.httpMethod == "GET" ? "Older status" : "Accepted task", "workers": []], for: request)
        }
        let base = URL(string: "http://fixture.invalid:7777")!
        try credentials.pair(base, hostID: "fixture", token: "fixture-token")
        try client.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: true)
        let state = CoordinatorState()
        state.observe(hostID: "fixture")
        let refresh = Task { await state.refresh(client: client, hostID: "fixture") }
        while release == nil { await Task.yield() }
        state.observe(hostID: "replacement")
        release?.resume()
        await refresh.value
        precondition(state.snapshot == nil, "A late status cannot overwrite another host's UI")
        blocked = false
        state.observe(hostID: "fixture")
        let worker = CoordinatorWorker(sessionId: "worker", workspaceId: "workspace", status: "idle")
        await state.submit(client: client, hostID: "fixture", text: "Queue this exact task", worker: worker)
        let submitted = requests.last!
        let body = try JSONSerialization.jsonObject(with: submitted.httpBody!) as! [String: Any]
        precondition(body["sessionId"] as? String == "worker" && body["workspaceId"] as? String == "workspace")
        precondition(body["text"] as? String == "Queue this exact task")
        precondition(UUID(uuidString: body["requestId"] as! String) != nil)
        precondition(submitted.value(forHTTPHeaderField: "Authorization") != nil)
        precondition(submitted.value(forHTTPHeaderField: "X-SlopZooka-Client-ID") != nil)
        release = nil
        blocked = true
        let oldPoll = Task { await state.refresh(client: client, hostID: "fixture") }
        while release == nil { await Task.yield() }
        await state.submit(client: client, hostID: "fixture", text: "New task", worker: worker)
        release?.resume()
        await oldPoll.value
        precondition(state.snapshot?.reply == "Accepted task", "A pre-submission status must not overwrite a newer accepted task")
        await state.stop(client: client, hostID: "fixture")
        precondition(requests.last!.url!.path == "/api/coordinator/stop")
        precondition(requests.last!.httpMethod == "POST")
        print("PASS: coordinator captures destination and request ID, uses authenticated transport, rejects late host state, and routes Stop independently")
    }
}
