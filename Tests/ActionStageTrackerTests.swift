import Foundation

@main
struct ActionStageTrackerTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }

        // Brain/agent reply without actions never marks the action done.
        var reply = ActionStageTracker(language: "uk")
        reply.begin(ai: true)
        check(reply.state == .active && reply.note == "AI", "AI thinking is active, not done")
        reply.replyReady(aiNote: "AI 1.2 с · $0.0010")
        check(reply.state == .pending, "Reply without actions is not done")
        check(reply.note == "без дій · AI 1.2 с · $0.0010", "Reply-only note says no actions")

        // Waiting for approval is shown as such, then a rejected plan is not done.
        let rejectedPlan = UUID()
        var rejected = ActionStageTracker(language: "en")
        rejected.begin(ai: true)
        rejected.replyReady(aiNote: nil)
        rejected.expect([rejectedPlan], approval: true)
        check(rejected.state == .waiting && rejected.note == "confirm", "Approval panel shows waiting")
        rejected.settle() // panel closed with no outcome: rejected or expired
        check(rejected.state != .done, "Rejected plan is never done")
        check(rejected.state == .pending && rejected.note == "not approved", "Rejected plan: pending, not approved")

        // Two plans in one panel: one failed → failed, whatever the order of callbacks.
        let a = UUID(), b = UUID()
        var mixed = ActionStageTracker(language: "uk")
        mixed.begin(ai: true)
        mixed.replyReady(aiNote: nil)
        mixed.expect([a, b], approval: true)
        mixed.resolve(a, .failed)
        check(mixed.state == .waiting, "Still waiting while one plan is unanswered")
        mixed.resolve(b, .done) // last callback succeeded
        mixed.settle()
        check(mixed.state == .failed, "One of two steps failed → failed")
        check(mixed.note == "частково · 1 з 2", "Partial note counts all plans")

        // All plans done → done.
        var all = ActionStageTracker(language: "uk")
        all.begin(ai: true)
        all.replyReady(aiNote: "AI 2.0 с")
        all.expect([a, b], approval: true)
        all.resolve(b, .done)
        all.resolve(a, .done)
        all.settle()
        check(all.state == .done && all.note == "AI 2.0 с", "All steps done → done")

        // One approved and done, the other rejected → failed (partly), not done.
        var partly = ActionStageTracker(language: "en")
        partly.expect([a, b], approval: true)
        partly.resolve(a, .done)
        partly.settle()
        check(partly.state == .failed && partly.note == "partly · 1 of 2", "Approved + rejected → failed, partly")

        // Brain: immediate steps are combined with later panel results.
        var brain = ActionStageTracker(language: "uk")
        brain.begin(ai: true)
        brain.record(.done)
        brain.replyReady(aiNote: nil)
        brain.expect([a], approval: true)
        check(brain.state == .waiting, "Immediate step + proposal → waiting")
        brain.resolve(a, .done)
        brain.settle()
        check(brain.state == .done, "Immediate and approved steps all done → done")
        var brainFail = ActionStageTracker(language: "uk")
        brainFail.begin(ai: true)
        brainFail.record(.failed)
        brainFail.record(.done)
        brainFail.replyReady(aiNote: nil)
        check(brainFail.state == .failed, "Immediate failure first, success last → failed")

        // Plans run at once: active while running; a stop after a failure counts the rest.
        var atOnce = ActionStageTracker(language: "uk")
        atOnce.replyReady(aiNote: nil)
        atOnce.expect([a, b], approval: false)
        check(atOnce.state == .active, "Plans running at once are active, not waiting")
        atOnce.resolve(a, .failed)
        atOnce.settle()
        check(atOnce.state == .failed && atOnce.note == "не виконано", "First plan failed, second never ran → failed")

        // Cancel while thinking or waiting: pending, cancelled.
        var thinking = ActionStageTracker(language: "uk")
        thinking.begin(ai: true)
        thinking.cancel()
        check(thinking.state == .pending && thinking.note == "скасовано", "Esc while thinking → pending, cancelled")
        var waiting = ActionStageTracker(language: "en")
        waiting.expect([a], approval: true)
        waiting.cancel()
        check(waiting.state == .pending && waiting.note == "cancelled", "Esc while waiting → pending, cancelled")
        waiting.settle()
        check(waiting.note == "cancelled", "Panel end after cancel keeps the cancelled note")

        // Cancel after the request settled changes nothing.
        var finished = all
        finished.cancel()
        check(finished == all, "Cancel after completion is ignored")

        // A late real outcome after settle still counts; unknown plans are ignored.
        var late = ActionStageTracker(language: "uk")
        late.expect([a], approval: true)
        late.settle()
        late.resolve(a, .done)
        check(late.state == .done, "Late real outcome replaces not-run")
        late.resolve(UUID(), .failed)
        check(late.state == .done, "Outcome of an unknown plan is ignored")

        // Local command: active without the AI note.
        var local = ActionStageTracker(language: "uk")
        local.begin(ai: false)
        check(local.state == .active && local.note == nil, "Local command is active without a note")

        print("ActionStageTrackerTests: \(count) assertions passed")
    }
}
