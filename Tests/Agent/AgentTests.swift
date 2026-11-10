import Foundation

@main struct AgentTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = try BudgetLedger(file: root.appendingPathComponent("budget.json"), monthlyLimit: try Money.usd("1"), requestLimit: try Money.usd("0.5"))
        let first = try await budget.reserve(try Money.usd("0.5"))
        let other = try BudgetLedger(file: root.appendingPathComponent("budget.json"), monthlyLimit: try Money.usd("1"), requestLimit: try Money.usd("0.5"))
        let second = try await other.reserve(try Money.usd("0.5"))
        do { _ = try await budget.reserve(try Money.usd("0.01")); fatalError("Monthly limit bypass") } catch BudgetError.exhausted { count += 1 }
        try await budget.settle(first, actual: try Money.usd("0.1"), complete: true)
        check(try await budget.snapshot().committed.micros == 600_000, "Reserved + charged across instances")
        try await other.settle(second, actual: nil, complete: false)
        check(try await budget.snapshot().committed.micros == 600_000, "Unknown usage keeps full reservation")
        do { try await budget.settle(second, actual: .zero, complete: true); fatalError("Double settlement") } catch BudgetError.unknownReservation { count += 1 }
        check(try Money.usd("0.0000001").micros == 1, "Round up fractional microdollar")
        check((try? Money.usd("-1")) == nil, "Negative price rejected")
        check((try? Money.usd("NaN")) == nil, "NaN rejected")
        let calendarFile = root.appendingPathComponent("calendar.json")
        let january = try BudgetLedger(file: calendarFile, monthlyLimit: try Money.usd("0.25"), now: { Date(timeIntervalSince1970: 1_767_225_600) })
        let janReservation = try await january.reserve(try Money.usd("0.25"))
        let february = try BudgetLedger(file: calendarFile, monthlyLimit: try Money.usd("0.25"), now: { Date(timeIntervalSince1970: 1_769_904_000) })
        check(try await february.snapshot().committed == .zero, "UTC month rollover")
        _ = try await february.reserve(try Money.usd("0.25"))
        try await january.settle(janReservation, actual: try Money.usd("0.1"), complete: true)
        check(try await february.snapshot().committed.micros == 250_000, "Old settlement cannot release current month reservation")
        check((try FileManager.default.attributesOfItem(atPath: calendarFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Ledger file private")
        let config = try GooseConfig(provider: "openai", model: "model-test", root: root.appendingPathComponent("goose"))
        try config.writeLockedConfiguration()
        let yaml = try String(contentsOf: config.configurationFile)
        check(yaml.contains("GOOSE_MODE: approve") && yaml.contains("GOOSE_DISABLE_SESSION_NAMING: true"), "Locked config")
        let env = config.environment(apiKey: "test-only-not-a-key")
        check(env["GOOSE_DISABLE_KEYRING"] == "1" && env["GOOSE_TELEMETRY_OFF"] == "1", "No extra key storage/telemetry")
        check(env["HOME"] == nil, "No HOME override")
        check(!yaml.contains("test-only-not-a-key"), "No key in config")
        let mock = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Agent/mock-acp.py")
        let rpc = JSONRPCProcess()
        try await rpc.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [mock.path], environment: ["PATH": "/usr/bin:/bin"])
        let client = GooseACPClient(transport: rpc)
        let session = try await client.initialize(cwd: root)
        check(session == "mock-session", "Initialize and create ACP v1 session")
        let answer = try await client.prompt("test")
        check(answer.text == "Вітаю!" && answer.cost?.micros == 162, "Chunks and cumulative usage")
        check(answer.stopReason == "end_turn", "Prompt completes")
        let denied = try await client.prompt("permission")
        check(denied.text == "rejected", "Permission denied by default, never always")
        await client.close()
        print("Agent tests: \(count) checks passed")
    }
}
