import Foundation

@main struct TurnControlTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) }; count += 1 }
        var queue = WakeScreeningQueue<String>()
        let old = queue.submit("old command")!
        check(queue.isCurrent(old.ticket), "Initial screening current")
        check(queue.submit("old pending") == nil, "Single-flight screening")
        queue.invalidate() // wake-off / mic-off / cancel / sleep
        check(!queue.isCurrent(old.ticket), "Old completion invalidated")
        check(queue.submit("new after re-enable") == nil, "Old inference retains serial slot")
        let next = queue.finish(old.ticket)
        check(next == "new after re-enable", "Only newest post-enable segment survives")
        let fresh = queue.submit(next!)!
        check(queue.isCurrent(fresh.ticket), "Fresh generation works")
        check(queue.finish(old.ticket) == nil && queue.isCurrent(fresh.ticket), "Duplicate old completion cannot release new slot")
        _ = queue.submit("pending")
        queue.invalidate()
        check(queue.finish(fresh.ticket) == nil, "Cancel clears queued audio segment")
        var activity = RequestActivity()
        check(!activity.canCancel(audioBusy: false, speaking: false), "Idle does not intercept Escape")
        check(activity.canCancel(audioBusy: true, speaking: false), "Audio capture/transcription cancellable")
        activity.begin(turn: 1, phase: .command)
        check(activity.canCancel(audioBusy: false, speaking: false), "Execution remains cancellable after ASR")
        activity.begin(turn: 1, phase: .agent)
        check(activity.canCancel(audioBusy: false, speaking: true), "AI acknowledgment cancellable")
        check(activity.canCancel(audioBusy: false, speaking: false), "AI remains cancellable when acknowledgment ends or replies are muted")
        activity.begin(turn: 1, phase: .approval)
        check(activity.canCancel(audioBusy: false, speaking: false), "Pending approval cancellable")
        activity.begin(turn: 2, phase: .agent)
        activity.finish(turn: 1)
        check(activity.turn == 2 && activity.active, "Old completion cannot hide new cancel controls")
        activity.finish(turn: 2)
        check(!activity.active, "Actual request completion clears controls")
        check(activity.canCancel(audioBusy: false, speaking: true), "Standalone reply can still be stopped")
        activity.begin(turn: 3, phase: .agent); activity.cancel()
        check(activity.turn == nil && !activity.active, "Cancel clears entire request")
        print("Turn control tests: \(count) checks passed")
    }
}
