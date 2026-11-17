import Foundation

@MainActor
private final class CoordinatorSpeech: SpeechCapturing {
    var state: SpeechCaptureState = .idle { didSet { onUpdate?() } }
    var transcript = "" { didSet { onUpdate?() } }
    var audioLevels = [Double]()
    var onUpdate: (() -> Void)?
    var onAudioLevels: (() -> Void)?
    var onFinished: (() -> Void)?
    var starts = 0
    func startListening(finishOnPause: Bool) async {
        precondition(state != .listening, "Only one microphone owner")
        precondition(!finishOnPause, "Coordinator uses the same hold flow as terminals")
        starts += 1
        state = .listening
    }
    func finishListening() { state = .finishing }
    func stopListening() { state = .idle }
    func clearTranscript() { transcript = "" }
    func finish(_ text: String) { transcript = text; state = .idle; onFinished?() }
}

@main
struct CoordinatorChecks {
    @MainActor
    static func main() async throws {
        defer { CompanionTestPreferences.clean() }
        var requests: [URLRequest] = []
        var release: CheckedContinuation<Void, Never>?
        var blocked = true
        var loseReply = true
        var responseOverride: [String: Any]?
        var tokens: [String: String] = [:]
        let credentials = CompanionCredentials(read: { tokens[$0] }, write: { tokens[$0] = $1 })
        let client = CompanionClient(defaults: CompanionTestPreferences.defaults, credentials: credentials) { request in
            requests.append(request)
            if request.url!.path == "/api/coordinator", request.httpMethod == "GET", blocked {
                await withCheckedContinuation { release = $0 }
            }
            if request.url!.path == "/api/coordinator", request.httpMethod == "POST", loseReply {
                loseReply = false
                throw URLError(.networkConnectionLost)
            }
            if let responseOverride { return try json(responseOverride, for: request) }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return try json(["available": true, "status": request.url!.path.hasSuffix("/stop") ? "stopped" : "completed",
                "requestId": body?["requestId"] ?? "old-request", "reply": request.httpMethod == "GET" ? "Older status" : "Accepted task", "workers": [], "workerSessionIds": []], for: request)
        }
        let base = URL(string: "http://fixture.invalid:7777")!
        try credentials.pair(base, hostID: "fixture", token: "fixture-token")
        try client.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: true)
        let state = CoordinatorState()
        state.select(CoordinatorContext(hostID: "fixture"))
        let refresh = Task { await state.refresh(client: client, hostID: "fixture") }
        await until { release != nil }
        state.select(CoordinatorContext(hostID: "replacement"))
        release?.resume()
        await refresh.value
        precondition(state.snapshot == nil, "A late status cannot overwrite another Mac's UI")
        blocked = false
        let destination = CoordinatorContext(hostID: "fixture", workspaceID: "workspace", sessionID: "worker", label: "Login")
        state.select(destination)
        let presenter = UUID()
        state.observeScene(presenter, active: true)
        await state.refresh(client: client, hostID: "fixture")

        let capture = CoordinatorSpeech()
        var countdown: CheckedContinuation<Void, Never>?
        let voice = TerminalVoiceController(capture: capture,
            waitBeforeSend: { await withCheckedContinuation { countdown = $0 } },
            isAvailable: { id, mode in mode == .coordinator ? state.canReceiveVoice(client: client) : true },
            canRetry: { state.canSubmit(client: client, command: $0) },
            rename: { _, _, _ in preconditionFailure("Voice command must not rename") },
            deliver: { command in try await state.submit(client: client, command: command) })
        state.canChangeContext = { voice.mode != .coordinator }
        voice.beginHold(CoordinatorState.sceneID, mode: .coordinator)
        await until { capture.state == .listening }
        capture.transcript = "do not send this"
        voice.beginTerminalHold("another-terminal")
        precondition(voice.mode == .coordinator && capture.starts == 1, "A draft cannot be stolen by another microphone surface")
        precondition(!state.select(CoordinatorContext(hostID: "replacement")))
        voice.endHold(CoordinatorState.sceneID)
        capture.finish("do not send this")
        await until { countdown != nil }
        voice.closeInput(CoordinatorState.sceneID)
        countdown?.resume(); countdown = nil
        await Task.yield()
        precondition(!requests.contains { $0.httpMethod == "POST" }, "Closing during countdown must send nothing")

        voice.beginHold(CoordinatorState.sceneID, mode: .coordinator)
        await until { capture.state == .listening }
        capture.transcript = "Queue this exact task"
        voice.endHold(CoordinatorState.sceneID)
        capture.finish("Queue this exact task, final words")
        await until { countdown != nil }
        precondition(!state.select(CoordinatorContext(hostID: "replacement")), "Context remains captured through finalization and countdown")
        countdown?.resume(); countdown = nil
        await until { voice.needsRetry }
        let first = requests.last!
        let firstBody = try JSONSerialization.jsonObject(with: first.httpBody!) as! [String: Any]
        precondition(firstBody["sessionId"] as? String == "worker" && firstBody["workspaceId"] as? String == "workspace")
        precondition(firstBody["text"] as? String == "Queue this exact task, final words")
        precondition(UUID(uuidString: firstBody["requestId"] as! String) != nil)
        precondition(first.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        precondition(first.value(forHTTPHeaderField: "X-SlopZooka-Client-ID") != nil)
        precondition(state.conversation.count == 1 && state.conversation[0].requestId == firstBody["requestId"] as? String)
        precondition(state.conversation[0].status == "unconfirmed", "An uncertain utterance stays visible with the same identity")
        voice.closeInput(CoordinatorState.sceneID)
        precondition(voice.needsRetry && !state.select(CoordinatorContext(hostID: "replacement")), "An uncertain delivery retains its context across closing")
        try client.accept(fixtureHealth("fixture", endpoint: base), endpoint: base, authenticated: true)
        // The host accepted the lost-reply request and is still reasoning. A
        // status poll must not turn safe confirmation into a disabled Retry.
        responseOverride = ["available": true, "status": "running", "requestId": firstBody["requestId"]!, "workers": [],
            "turns": [["requestId": firstBody["requestId"]!, "text": firstBody["text"]!, "status": "running"]]]
        await state.refresh(client: client, hostID: "fixture")
        precondition(state.conversation.count == 1 && !state.canReceiveVoice(client: client))
        voice.send()
        await until { voice.mode == nil }
        responseOverride = nil
        precondition(first.httpBody == requests.last!.httpBody, "Retry must confirm the identical command, never create another request")
        precondition(voice.lastSubmission?.commandID == firstBody["requestId"] as? String)
        precondition(state.context == destination)
        await state.refresh(client: client, hostID: "fixture")

        release = nil
        blocked = true
        let oldPoll = Task { await state.refresh(client: client, hostID: "fixture") }
        await until { release != nil }
        let next = TerminalVoiceCommand(targetID: CoordinatorState.sceneID, commandID: UUID().uuidString, text: "Next", destination: .coordinator)
        try await state.submit(client: client, command: next)
        release?.resume()
        await oldPoll.value
        precondition(state.snapshot?.requestId == next.commandID, "A pre-submission poll cannot overwrite the new request")
        state.observeScene(UUID(), active: false)
        precondition(state.sceneActive, "An old scene must not deactivate the current composer")
        state.observeScene(presenter, active: false)
        precondition(!state.canReceiveVoice(client: client))
        precondition(state.snapshot?.requestId == next.commandID, "Hiding the window does not stop or resubmit a task")
        let beforeStaleStop = requests.count
        await state.stop(client: client, hostID: "fixture", requestID: firstBody["requestId"] as! String)
        precondition(requests.count == beforeStaleStop, "A stale button action cannot target the next request")
        await state.stop(client: client, hostID: "fixture", requestID: next.commandID)
        precondition(requests.last!.url!.path == "/api/coordinator/stop")
        let stopBody = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: String]
        precondition(stopBody["requestId"] == next.commandID, "Stop carries the request captured by the UI")
        precondition(state.statusText == "Stopped" && !state.responseText.contains("Accepted"), "Current cancellation state replaces an earlier acknowledgement")
        blocked = false
        responseOverride = ["available": true, "status": "completed", "requestId": "current", "reply": "The agent is running", "workerSessionIds": ["ours"],
            "workers": [["sessionId": "ours", "workspaceId": "workspace", "status": "completed", "result": "Counter 3"],
                        ["sessionId": "unrelated", "workspaceId": "other", "status": "running"]]]
        await state.refresh(client: client, hostID: "fixture")
        precondition(state.statusText == "Done" && state.responseText == "Counter 3" && !state.isWorking,
            "Current-request results supersede stale acknowledgements; unrelated workers cannot keep this request busy")
        responseOverride?["status"] = "failed"
        responseOverride?["reply"] = "Cancellation could not be confirmed; agent may still be working"
        responseOverride?["workers"] = [["sessionId": "ours", "workspaceId": "workspace", "status": "running"]]
        await state.refresh(client: client, hostID: "fixture")
        precondition(state.statusText == "Needs attention" && state.responseText.contains("could not be confirmed") && state.canStop,
            "Uncertain cancellation must remain visible and retryable while the agent is active")
        responseOverride?["turns"] = [
            ["requestId": "earlier", "text": "Name the window", "status": "completed", "reply": "Named **Login**.", "workStatus": "completed"],
            ["requestId": "current", "text": "Run its test", "status": "failed", "reply": "Cannot confirm Stop", "workStatus": "running"]
        ]
        await state.refresh(client: client, hostID: "fixture")
        precondition(state.conversation.count == 2 && state.conversation[0].reply == "Named **Login**.")
        precondition(state.conversation[0].progress == "Completed" && state.conversation[1].progress == "Needs attention")
        state.observeScene(presenter, active: true)
        precondition(state.select(CoordinatorContext(hostID: "fixture")))
        precondition(state.conversation.count == 2, "Changing workspace context keeps the same conversation")
        precondition(state.select(CoordinatorContext(hostID: "another-host")))
        precondition(state.conversation.isEmpty, "A different host must not inherit another Mac's conversation")
        print("PASS: shared coordinator voice keeps final words, destination and retry ID; closing cancels only unsent speech; one microphone and late-response guards preserve task ownership")
    }

    @MainActor
    private static func until(file: StaticString = #file, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Coordinator condition timed out", file: file, line: line)
    }
}
