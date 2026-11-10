import Foundation

@main struct TransportTests {
    static func client() async throws -> GooseACPClient {
        let rpc = JSONRPCProcess()
        try await rpc.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [FileManager.default.currentDirectoryPath + "/Tests/Agent/mock-acp.py"], environment: ["PATH": "/usr/bin:/bin"])
        let client = GooseACPClient(transport: rpc)
        _ = try await client.initialize(cwd: FileManager.default.temporaryDirectory)
        return client
    }
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        for (scenario, expected) in [("bad-json", AgentError.invalidMessage), ("exit", .closed), ("error", .provider(-32000))] {
            let client = try await client()
            do { _ = try await client.prompt(scenario); fatalError("Expected failure") }
            catch let error as AgentError { check(error == expected, scenario) }
            await client.close()
        }
        let timed = try await client()
        do { _ = try await timed.prompt("slow", timeout: 0.1); fatalError("Expected timeout") }
        catch let error as AgentError { check(error == .timeout, "Bounded timeout") }
        await timed.close()
        let cancelled = try await client()
        let task = Task { try await cancelled.prompt("slow") }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") }
        catch { check(error is CancellationError || (error as? AgentError) == .cancelled, "Task cancellation") }
        await cancelled.close()
        let usage = try await client()
        let answer = try await usage.prompt("invalid-cost")
        check(answer.cost == nil, "Foreign currency cannot become USD")
        let foreign = try await usage.prompt("foreign")
        check(foreign.text == "correct", "Other-session chunks ignored")
        await usage.close()
        let capped = try await client(); await capped.setCostCeiling(Money(micros: 100))
        do { _ = try await capped.prompt("test"); fatalError("Expected spending stop") }
        catch { count += 1 }
        check(await capped.reportedCost()?.micros == 162, "Cost retained after stop")
        await capped.close()
        let over = try await client(); await over.setCostCeiling(Money(micros: 100))
        do { _ = try await over.prompt("invalid-then-over"); fatalError("Expected cap stop") }
        catch { count += 1 }
        check(await over.reportedCost()?.micros == 500_000, "Known overrun retained despite malformed earlier usage")
        await over.close()
        print("Transport tests: \(count) checks passed")
    }
}
