import Foundation

/// Where an agent answer spends its time, observed from outside the agent:
/// process start, first streamed words, how many model rounds (usage
/// updates) and plan proposals. Wraps the pinned launcher without changing it.
actor AgentTimingProbe {
    struct Snapshot: Sendable {
        var launch: Double?
        var firstText: Double?
        var rounds = 0
        var proposals = 0
    }
    private var started: TimeInterval = 0
    private var current = Snapshot()

    func begin() {
        started = ProcessInfo.processInfo.systemUptime
        current = Snapshot()
    }
    func snapshot() -> Snapshot { current }

    fileprivate func launched() { current.launch = ProcessInfo.processInfo.systemUptime - started }
    fileprivate func observe(_ kind: GooseStreamEvent.Kind) {
        switch kind {
        case .text:
            if current.firstText == nil { current.firstText = ProcessInfo.processInfo.systemUptime - started }
        case .usage: current.rounds += 1
        case .proposalAllowed: current.proposals += 1
        case .permissionRejected: break
        }
    }
}

struct TimedGooseLauncher: GooseLaunching {
    let inner: GooseLaunching
    let probe: AgentTimingProbe

    func launch(config: GooseConfig, apiKey: String) async throws -> GooseACPClient {
        let client = try await inner.launch(config: config, apiKey: apiKey)
        await probe.launched()
        // Subscribed before the session starts; ends when the client closes.
        let events = await client.stream()
        let probe = self.probe
        Task { for await event in events { await probe.observe(event.kind) } }
        return client
    }
}
