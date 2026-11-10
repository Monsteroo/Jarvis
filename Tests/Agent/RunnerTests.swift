import Foundation

@main struct RunnerTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try BudgetLedger(file: root.appendingPathComponent("ledger.json"), monthlyLimit: try Money.usd("1"))
        let config = try GooseConfig(provider: "openai", model: "mock", root: root.appendingPathComponent("goose"))
        let launcher = MockLauncher()
        let runner = BudgetedGooseAgent(config: config, ledger: ledger, launcher: launcher)
        let answer = try await runner.run(text: "test", language: "uk", apiKey: "test-only-not-a-key")
        check(answer.text == "Вітаю!", "Complete runner")
        check(try await ledger.snapshot().committed.micros == 162, "Repeated cost charged once")
        do { _ = try await runner.run(text: "error", language: "en", apiKey: "test-only-not-a-key"); fatalError("Provider failure") }
        catch let error as AgentError { check(error == .provider(-32000), "Provider error propagated") }
        check(try await ledger.snapshot().committed.micros == 250_162, "Interrupted usage reserves full ceiling")
        _ = try await runner.run(text: "invalid-cost", language: "en", apiKey: "test-only-not-a-key")
        check(try await ledger.snapshot().committed.micros == 500_162, "Unsupported currency not free")
        let actionRunner = RunnerActionRecorder(), broker = AgentActionBroker(executor: actionRunner)
        let turn = UUID()
        let context = AgentPlanningContext(broker: broker, turn: turn,
            helperExecutable: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/.build/agent/jarvis-mcp-helper"))
        let planned = try await runner.run(text: "proposal", language: "uk", apiKey: "test-only-not-a-key", planning: context)
        check(planned.text == "plan proposed", "Budgeted planning path")
        let proposals = await broker.pendingPlans()
        let effectsBeforeApproval = await actionRunner.count
        check(proposals.count == 1 && effectsBeforeApproval == 0, "Proposal survives normal process close without execution")
        let approval = try await broker.approve(plan: proposals[0].id)
        _ = try await broker.commit(plan: proposals[0].id, token: approval)
        check(await actionRunner.count == 1, "Budgeted proposal commits only after native approval")
        await broker.cancel(turn: turn)
        let turns = config.root.appendingPathComponent("turns")
        check(try FileManager.default.contentsOfDirectory(atPath: turns.path).isEmpty, "Turn state cleaned on success and failure")
        check(try Money.usd("0.25").micros == 250_000, "Exact decimal parsing")
        check((try? Money.usd("1oops")) == nil, "Reject trailing numeric garbage")
        let tight = try BudgetLedger(file: root.appendingPathComponent("tight.json"), monthlyLimit: try Money.usd("0.25"))
        let hold = try await tight.reserve(try Money.usd("0.25"))
        let blocked = BudgetedGooseAgent(config: config, ledger: tight, launcher: launcher)
        let launches = await launcher.count
        do { _ = try await blocked.run(text: "test", language: "uk", apiKey: "dummy"); fatalError("Budget bypass") }
        catch BudgetError.exhausted { count += 1 }
        check(await launcher.count == launches, "No process launch when exhausted")
        try await tight.settle(hold, actual: try Money.usd("0.30"), complete: true)
        check(try await tight.snapshot().committed.micros == 300_000, "Observed overspend retained")
        let broken = root.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: broken)
        let corrupt = try BudgetLedger(file: broken)
        do { _ = try await corrupt.reserve(try Money.usd("0.1")); fatalError("Corrupt ledger reset") }
        catch BudgetError.corruptLedger { count += 1 }
        print("Runner tests: \(count) checks passed")
    }
}
actor MockLauncher: GooseLaunching {
    private(set) var count = 0
    func launch(config: GooseConfig, apiKey: String) async throws -> GooseACPClient {
        count += 1
        try config.writeLockedConfiguration()
        let rpc = JSONRPCProcess()
        try await rpc.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [FileManager.default.currentDirectoryPath + "/Tests/Agent/mock-acp.py"], environment: ["PATH": "/usr/bin:/bin"])
        return GooseACPClient(transport: rpc)
    }
}

actor RunnerActionRecorder: TypedActionRunning {
    private(set) var count = 0
    func run(_ action: Action, language: String) async -> CommandOutcome { count += 1; return .done(summary: "ok") }
}
