import Foundation
import Darwin

@main struct IPCTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        let runner = IPCRecordingRunner()
        let broker = AgentActionBroker(executor: runner)
        let turn = UUID(); await broker.begin(turn: turn, language: "uk")
        let bridge = AgentMCPBridge(broker: broker, turn: turn)
        let server = try AgentIPCServer(bridge: bridge)
        let endpoint = server.endpoint
        check((try FileManager.default.attributesOfItem(atPath: endpoint.socketPath)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private socket")
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/.build/agent/jarvis-mcp-helper")
        let descriptor = try GooseMCPServer(helper: helper, endpoint: endpoint)
        let rpc = JSONRPCProcess()
        try await rpc.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [FileManager.default.currentDirectoryPath + "/Tests/Agent/mock-acp.py"], environment: ["PATH": "/usr/bin:/bin"])
        let client = GooseACPClient(transport: rpc)
        _ = try await client.initialize(cwd: FileManager.default.temporaryDirectory, mcpServer: descriptor)
        let answer = try await client.prompt("proposal")
        check(answer.text == "plan proposed", "ACP to helper to app-owned broker")
        let plans = await broker.pendingPlans()
        check(plans.count == 1 && plans[0].action == .openApp("terminal"), "Exact typed proposal arrives")
        check(await runner.count == 0, "No execution before native approval")
        let token = try await broker.approve(plan: plans[0].id)
        _ = try await broker.commit(plan: plans[0].id, token: token)
        check(await runner.count == 1, "Exactly one native-approved execution")
        let bad = try await client.prompt("unsafe-proposal")
        check(bad.text == "rejected", "Other tools remain rejected")
        let mutated = try await client.prompt("proposal-mutated")
        check(mutated.text == "rejected", "Changed arguments cannot reuse proposal permission")
        await client.close()
        let denied = await Task.detached { () -> Bool in
            do {
                let wrong = AgentIPCEndpoint(socketPath: endpoint.socketPath, capability: String(repeating: "0", count: 64))
                let connection = try AgentIPCConnection(endpoint: wrong)
                _ = try connection.exchange(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")]))
                return false
            } catch { return true }
        }.value
        check(denied, "Wrong capability rejected")
        await broker.cancel(turn: turn); await server.stop()
        check(!FileManager.default.fileExists(atPath: endpoint.socketPath), "Socket removed on stop")
        check(await runner.count == 1, "No hidden execution after shutdown")
        print("IPC tests: \(count) checks passed")
    }
}
actor IPCRecordingRunner: TypedActionRunning {
    private(set) var count = 0
    func run(_ action: Action, language: String) async -> CommandOutcome { count += 1; return .done(summary: "ok") }
}
