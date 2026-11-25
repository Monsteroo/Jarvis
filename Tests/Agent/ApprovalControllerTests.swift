import Foundation

@main struct ApprovalControllerTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) }; count += 1 }
        let executor = PanelTestRunner(), broker = AgentActionBroker(executor: executor)
        let turn = UUID(); await broker.begin(turn: turn, language: "uk")
        let a = try await broker.propose(.openApp("terminal"), turn: turn)
        let b = try await broker.propose(.openURL("https://example.com"), turn: turn)
        var ended = 0, outcomes = 0
        let controller = AgentApprovalController(broker: broker, turn: turn, language: "uk", onEnd: { ended += 1 }) { _, _ in outcomes += 1 }
        let uiPlan = AgentActionPlan(id: UUID(), turn: turn, action: .uiPress(app: "Google Chrome", snapshotID: "abcd1234", ref: "e4"), expiresAt: Date().addingTimeInterval(60), detail: "Google Chrome: AXLink «Video\u{202E}»")
        let renderedDesc = controller.description(for: uiPlan)
        check(renderedDesc.contains("AXLink") && renderedDesc.contains("\\u{202e}") && renderedDesc.contains("[e4]"), "UI plan renders resolved element detail and escapes bidi")
        await controller.refresh() // Populate state without displaying any windows.
        check(controller.plans.count == 2, "Both plans loaded")
        controller.reject(a)
        check(ended == 0, "Rejecting one plan keeps remaining request cancellable")
        controller.approve(b)
        for _ in 0..<100 where ended == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        check(ended == 1 && outcomes == 1, "Completion clears request activity once")
        check(await executor.count == 1, "Exactly one fake action")
        controller.dismiss()
        check(ended == 1, "Closing completed panel does not emit stale completion")
        let other = UUID(); await broker.begin(turn: other, language: "uk")
        let plan = try await broker.propose(.openApp("terminal"), turn: other)
        var cancelled = 0
        let next = AgentApprovalController(broker: broker, turn: other, language: "uk", onEnd: { cancelled += 1 })
        await next.refresh(); next.dismiss()
        check(cancelled == 1, "Panel cancellation clears active controls")
        next.approve(plan)
        try await Task.sleep(nanoseconds: 30_000_000)
        check(await executor.count == 1, "Dismissed panel cannot execute")
        let emptyTurn = UUID(); await broker.begin(turn: emptyTurn, language: "uk")
        var emptyEnded = 0
        let empty = AgentApprovalController(broker: broker, turn: emptyTurn, language: "uk", onEnd: { emptyEnded += 1 })
        await empty.show() // No plans: must not open a window or leave cancel activity stuck.
        check(emptyEnded == 1, "Empty or expired plan list clears request activity")
        print("Approval controller tests: \(count) checks passed")
    }
}
actor PanelTestRunner: TypedActionRunning {
    private(set) var count = 0
    func run(_ action: Action, language: String) async -> CommandOutcome { count += 1; return .done(summary: "ok") }
}
