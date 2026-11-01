import Foundation

@main
struct ImmersiveWorkspaceChecks {
    @MainActor
    static func main() async {
        let state = ImmersiveWorkspaceState()
        var opens = 0
        var closes = 0
        var pending: [CheckedContinuation<ImmersiveWorkspaceState.OpenResult, Never>] = []
        let open: () async -> ImmersiveWorkspaceState.OpenResult = {
            opens += 1
            return await withCheckedContinuation { pending.append($0) }
        }
        let dismiss: () async -> Void = { closes += 1; state.observe(isPresented: false) }

        let first = Task { await state.setEnabled(true, open: open, dismiss: dismiss) }
        while pending.isEmpty { await Task.yield() }
        await state.setEnabled(true, open: open, dismiss: dismiss)
        await state.setEnabled(false, open: open, dismiss: dismiss)
        precondition(opens == 1 && closes == 0, "Rapid input must not overlap native transitions")
        pending.removeFirst().resume(returning: .cancelled)
        await first.value
        precondition(!state.isPresented && !state.isTransitioning && state.error == nil)
        await state.setEnabled(true, open: { .failed }, dismiss: dismiss)
        precondition(!state.isPresented && state.error != nil, "Failure must leave a retryable toggle")
        await state.setEnabled(true, open: { .opened }, dismiss: dismiss)
        precondition(state.isPresented && state.error == nil, "Successful entry fills the gap before the scene callback")
        await state.setEnabled(true, open: open, dismiss: dismiss)
        precondition(pending.isEmpty, "Delayed appearance must not allow a duplicate open")
        state.observe(isPresented: true)
        await state.setEnabled(false, open: open, dismiss: dismiss)
        precondition(!state.isPresented && closes == 1)
        print("PASS: immersive entry, cancellation, and retry reflect actual scene visibility")

        state.observe(isPresented: true)
        var pendingDismiss: CheckedContinuation<Void, Never>?
        let closing = Task {
            await state.setEnabled(false, open: open, dismiss: {
                await withCheckedContinuation { pendingDismiss = $0 }
            })
        }
        while pendingDismiss == nil { await Task.yield() }
        state.observe(isPresented: false)
        await state.setEnabled(true, open: open, dismiss: dismiss)
        precondition(state.isTransitioning && pending.isEmpty, "Disappearance must not unlock an unfinished native dismissal")
        pendingDismiss?.resume()
        await closing.value
        precondition(!state.isPresented && !state.isTransitioning)

        let stale = Task { await state.setEnabled(true, open: open, dismiss: dismiss) }
        while pending.isEmpty { await Task.yield() }
        state.observe(isPresented: true)
        state.observe(isPresented: false)
        await state.setEnabled(true, open: open, dismiss: dismiss)
        precondition(pending.count == 1, "System dismissal must not allow overlapping open requests")
        pending.removeFirst().resume(returning: .opened)
        await stale.value
        precondition(!state.isPresented && !state.isTransitioning, "Late success must not resurrect a dismissed scene")
        await state.setEnabled(true, open: { state.observe(isPresented: true); return .opened }, dismiss: dismiss)
        precondition(state.isPresented, "Entry must work again once the previous call finishes")
        state.observe(isPresented: false)
        precondition(!state.isPresented && !ImmersiveWorkspaceState().isPresented)
        print("PASS: opening and closing stay serialized across system dismissal; late replies cannot restore visibility")
    }
}
