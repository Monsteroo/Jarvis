import Foundation

@main struct GooseSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply pinned goose-acp executable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateAgentFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try GooseConfig.openAI(root: root.appendingPathComponent("goose"), model: "gpt-4o-mini")
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        try config.verifyExecutable(binary)
        let http = Process()
        http.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let portFile = root.appendingPathComponent("port")
        http.arguments = [FileManager.default.currentDirectoryPath + "/Tests/Agent/Integration/mock-openai.py", portFile.path]
        http.environment = ["PATH": "/usr/bin:/bin"]
        http.standardOutput = FileHandle.nullDevice; http.standardError = FileHandle.nullDevice
        try http.run(); defer { if http.isRunning { http.terminate() } }
        var port: String?
        for _ in 0..<40 {
            port = try? String(contentsOf: portFile)
            if port != nil { break }; try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let port, UInt16(port) != nil else { throw AgentError.unavailable }
        let executor = SmokeActionRunner(), broker = AgentActionBroker(executor: executor)
        let turn = UUID(); await broker.begin(turn: turn, language: "uk")
        let ipc = try AgentIPCServer(bridge: AgentMCPBridge(broker: broker, turn: turn))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/.build/agent/jarvis-mcp-helper")
        let descriptor = try GooseMCPServer(helper: helper, endpoint: ipc.endpoint)
        try config.writeLockedConfiguration()
        var env = config.environment(apiKey: "mock-local-not-a-key")
        env["OPENAI_HOST"] = "http://127.0.0.1:" + port
        // Stop models.dev/catalog traffic going outside this local fixture.
        env["HTTPS_PROXY"] = "http://127.0.0.1:9"; env["HTTP_PROXY"] = "http://127.0.0.1:9"
        env["NO_PROXY"] = "127.0.0.1,localhost"
        let rpc = JSONRPCProcess()
        try await rpc.start(executable: binary, environment: env, cwd: config.root.appendingPathComponent("work"))
        let client = GooseACPClient(transport: rpc)
        do {
            _ = try await client.initialize(cwd: config.root.appendingPathComponent("work"), mcpServer: descriptor)
            let answer = try await client.prompt("Запропонуй відкрити Terminal через інструмент propose_action.", timeout: 30)
            let plans = await broker.pendingPlans()
            guard plans.count == 1, plans[0].action == .openApp("terminal"), await executor.count == 0 else { throw AgentError.invalidMessage }
            let token = try await broker.approve(plan: plans[0].id)
            _ = try await broker.commit(plan: plans[0].id, token: token)
            guard await executor.count == 1, answer.stopReason == "end_turn" else { throw AgentError.invalidMessage }
            await client.close(); await ipc.stop()
            print("Pinned Goose runtime smoke: ACP → MCP helper → app broker → explicit approval passed (fake action, local model).")
        } catch {
            await client.close(); await broker.cancel(turn: turn); await ipc.stop(); throw error
        }
    }
}
actor SmokeActionRunner: TypedActionRunning {
    private(set) var count = 0
    func run(_ action: Action, language: String) async -> CommandOutcome { count += 1; return .done(summary: "ok") }
}
