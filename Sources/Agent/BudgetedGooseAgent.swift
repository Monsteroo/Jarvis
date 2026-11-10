import Foundation

protocol GooseLaunching: Sendable {
    func launch(config: GooseConfig, apiKey: String) async throws -> GooseACPClient
}
struct PinnedGooseLauncher: GooseLaunching {
    let executable: URL
    func launch(config: GooseConfig, apiKey: String) async throws -> GooseACPClient {
        try config.verifyExecutable(executable)
        try config.writeLockedConfiguration()
        let transport = JSONRPCProcess()
        try await transport.start(executable: executable, environment: config.environment(apiKey: apiKey), cwd: config.root.appendingPathComponent("work"))
        return GooseACPClient(transport: transport)
    }
}

/// Text-only first integration. Each request gets a fresh process/session and a durable reservation.
/// It does NOT enable model-triggered side effects; MCP proposal wiring is a separate integration.
actor BudgetedGooseAgent {
    private let config: GooseConfig
    private let ledger: BudgetLedger
    private let launcher: GooseLaunching
    private let maximum: Money
    private var busy = false
    init(config: GooseConfig, ledger: BudgetLedger, launcher: GooseLaunching, maximum: Money = Money(micros: 250_000)) {
        self.config = config; self.ledger = ledger; self.launcher = launcher; self.maximum = maximum
    }
    func run(text: String, language: String, apiKey: String) async throws -> GooseAnswer {
        guard !busy else { throw AgentError.busy }
        guard ["uk", "en"].contains(language), !text.isEmpty, text.count <= 15_900,
              !apiKey.isEmpty, apiKey.utf8.count <= 8192 else { throw AgentError.invalidConfiguration }
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        let turnConfig = try GooseConfig(provider: config.provider, model: config.model, root: config.root.appendingPathComponent("turns/" + UUID().uuidString))
        let reservation = try await ledger.reserve(maximum)
        var client: GooseACPClient?
        var promptStarted = false
        do {
            let launched = try await launcher.launch(config: turnConfig, apiKey: apiKey)
            client = launched
            _ = try await launched.initialize(cwd: turnConfig.root.appendingPathComponent("work"))
            await launched.setCostCeiling(maximum)
            try Task.checkCancellation()
            promptStarted = true
            let instruction = language == "uk" ? "Відповідай українською.\n\n" : "Reply in English.\n\n"
            let answer = try await launched.prompt(instruction + text)
            await launched.close()
            // A zero price can mean an unknown model price; do not silently treat it as free.
            let complete = answer.cost.map { $0.micros > 0 } ?? false
            try await ledger.settle(reservation, actual: answer.cost, complete: complete)
            try? FileManager.default.removeItem(at: turnConfig.root)
            return answer
        } catch {
            let cost = await client?.reportedCost()
            await client?.close()
            // A setup failure before prompt needs no model charge. Interrupted inference does.
            do { try await ledger.settle(reservation, actual: promptStarted ? cost : .zero, complete: !promptStarted) }
            catch { /* Failed settlement leaves the durable reservation in place, blocking reuse. */ }
            try? FileManager.default.removeItem(at: turnConfig.root)
            throw error
        }
    }
}
