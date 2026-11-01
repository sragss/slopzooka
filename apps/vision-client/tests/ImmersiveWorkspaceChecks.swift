import Foundation

@main
struct ImmersiveWorkspaceChecks {
    @MainActor
    static func main() async {
        let suite = "slz-immersion-checks-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ImmersiveWorkspaceState(defaults: defaults)
        var opens = 0
        var closes = 0
        var pending: [CheckedContinuation<ImmersiveWorkspaceState.OpenResult, Never>] = []
        let open: () async -> ImmersiveWorkspaceState.OpenResult = {
            opens += 1
            return await withCheckedContinuation { pending.append($0) }
        }
        let dismiss: () async -> Void = { closes += 1 }

        let first = Task { await state.setEnabled(true, open: open, dismiss: dismiss) }
        while pending.isEmpty { await Task.yield() }
        precondition(state.isEnabled && state.isTransitioning)
        state.didAppear()
        await state.setEnabled(true, open: open, dismiss: dismiss)
        await state.setEnabled(false, open: open, dismiss: dismiss)
        precondition(opens == 1 && closes == 0, "Rapid input must not overlap native transitions")
        pending.removeFirst().resume(returning: .cancelled)
        await first.value
        precondition(state.phase == .inactive && state.error == nil)

        await state.setEnabled(true, open: { .failed }, dismiss: dismiss)
        precondition(!state.isEnabled && state.error != nil, "Failure must leave a retryable toggle")
        await state.setEnabled(true, open: { .opened }, dismiss: dismiss)
        precondition(state.phase == .active && state.error == nil)
        await state.setEnabled(false, open: open, dismiss: {
            closes += 1
            state.didDisappear()
        })
        precondition(state.phase == .inactive && closes == 1)
        await state.setEnabled(true, open: { .opened }, dismiss: dismiss)
        var pendingDismiss: CheckedContinuation<Void, Never>?
        let closing = Task {
            await state.setEnabled(false, open: open, dismiss: {
                await withCheckedContinuation { pendingDismiss = $0 }
            })
        }
        while pendingDismiss == nil { await Task.yield() }
        state.didDisappear()
        precondition(state.phase == .closing && !state.isEnabled)
        await state.setEnabled(true, open: open, dismiss: dismiss)
        precondition(pending.isEmpty, "Do not reopen until native dismissal has finished")
        pendingDismiss?.resume()
        await closing.value
        precondition(state.phase == .inactive)
        print("PASS: immersive entry, cancellation, retry, and exit serialize native transitions")

        let stale = Task { await state.setEnabled(true, open: open, dismiss: dismiss) }
        while pending.isEmpty { await Task.yield() }
        state.didDisappear()
        let replacement = Task { await state.setEnabled(true, open: open, dismiss: dismiss) }
        while pending.count < 2 { await Task.yield() }
        pending.removeFirst().resume(returning: .opened)
        await stale.value
        precondition(state.phase == .opening, "A late reply must not complete a newer request")
        pending.removeFirst().resume(returning: .opened)
        await replacement.value
        state.didDisappear()
        precondition(state.phase == .inactive, "System dismissal must update every control")
        state.wrist = .right
        let restarted = ImmersiveWorkspaceState(defaults: defaults)
        precondition(restarted.wrist == .right && restarted.phase == .inactive,
            "Remember the chosen wrist, but never reopen immersion at launch")
        print("PASS: late replies and system dismissal cannot resurrect immersion; only wrist preference persists")
    }
}
