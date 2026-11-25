import Foundation

@main struct ApprovalTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        let executor = RecordingActionRunner()
        let broker = AgentActionBroker(executor: executor)
        let turn = UUID()
        await broker.begin(turn: turn, language: "uk")
        let plan = try await broker.propose(.openURL("https://example.com"), turn: turn)
        check(await executor.count == 0, "Planning never executes")
        let token = try await broker.approve(plan: plan.id)
        let result = try await broker.commit(plan: plan.id, token: token)
        check(result == .done(summary: "ok"), "Approved action result")
        check(await executor.count == 1, "Exactly one effect")
        do { _ = try await broker.commit(plan: plan.id, token: token); fatalError("Replay") } catch ApprovalError.invalidToken { count += 1 }
        let other = try await broker.propose(.openApp("terminal"), turn: turn)
        do { _ = try await broker.commit(plan: other.id, token: token); fatalError("Mismatched action") } catch ApprovalError.invalidToken { count += 1 }
        let otherToken = try await broker.approve(plan: other.id)
        await broker.cancel(turn: turn)
        do { _ = try await broker.commit(plan: other.id, token: otherToken); fatalError("Cancelled plan") } catch ApprovalError.invalidToken { count += 1 }
        check(await executor.count == 1, "Cancelled plan has no effect")
        do { _ = try await broker.propose(.openApp("terminal"), turn: turn); fatalError("Cancelled turn") } catch ApprovalError.inactiveTurn { count += 1 }
        let turn2 = UUID(); await broker.begin(turn: turn2, language: "en")
        do { _ = try await broker.propose(.dictate("no implicit focus"), turn: turn2); fatalError("LLM dictation blocked") } catch ApprovalError.unsupportedAction { count += 1 }
        let bridge = AgentMCPBridge(broker: broker, turn: turn2)
        let discovery = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("server/discover")]))
        check(discovery?["error"]["code"].decimal == -32601, "Goose legacy fallback")
        let initResult = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25")])]))
        check(initResult?["result"]["protocolVersion"].string == "2025-11-25", "MCP handshake")
        let proposal = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("openApp"), "target": .string("terminal")])])]))
        check(proposal?["result"]["isError"] == .bool(false), "Typed proposal accepted")
        check(await executor.count == 1, "MCP proposal still cannot execute")
        let attack = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(4), "method": .string("tools/call"), "params": .object(["name": .string("commit_action"), "arguments": .object([:])])]))
        check(attack?["result"]["isError"] == .bool(true), "Model has no commit endpoint")
        let uiProposal = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(5), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("uiPress"), "target": .string("Google Chrome"), "snapshot": .string("abcd1234"), "ref": .string("e3")])])]))
        check(uiProposal?["result"]["isError"] == .bool(false), "Typed uiPress proposal accepted")
        let blockedKeychain = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(6), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("uiSnapshot"), "target": .string("1Password")])])]))
        check(blockedKeychain?["result"]["isError"] == .bool(true), "Password manager proposal blocked")
        let tabDecode = try AgentMCPBridge.decodeAction(.object(["kind": .string("tabCloseLast")]))
        check(tabDecode == .tabCloseLast(nil), "tabCloseLast without target decoded")
        let setDecode = try AgentMCPBridge.decodeAction(.object(["kind": .string("uiSetValue"), "target": .string("Notes"), "snapshot": .string("abcd1234"), "ref": .string("e2"), "text": .string("Draft")]))
        check(setDecode == .uiSetValue(app: "Notes", snapshotID: "abcd1234", ref: "e2", text: "Draft"), "uiSetValue decoded")
        let shortcutDecode = try AgentMCPBridge.decodeAction(.object(["kind": .string("runShortcut"), "target": .string("Connect AirPods")]))
        check(shortcutDecode == .runShortcut("Connect AirPods"), "runShortcut decoded")
        let badShortcutProposal = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(7), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("runShortcut"), "target": .string("Dark; rm -rf /")])])]))
        check(badShortcutProposal?["result"]["isError"] == .bool(true), "Shell-injection shortcut proposal rejected")
        let goodShortcutProposal = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(8), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("runShortcut"), "target": .string("Connect AirPods")])])]))
        check(goodShortcutProposal?["result"]["isError"] == .bool(false), "Valid runShortcut proposal accepted (awaits approval)")
        check(await executor.count == 1, "MCP runShortcut proposal still cannot execute")
        // Clipboard actions: clipboardPaste blocked for Goose/MCP, clipboardRead/Write/Undo decode cleanly.
        do { _ = try await broker.propose(.clipboardPaste("no implicit paste"), turn: turn2); fatalError("Goose clipboardPaste blocked") } catch ApprovalError.unsupportedAction { count += 1 }
        let blockedPasteMCP = await bridge.handle(.object(["jsonrpc": .string("2.0"), "id": .number(9), "method": .string("tools/call"), "params": .object(["name": .string("propose_action"), "arguments": .object(["kind": .string("clipboardPaste"), "text": .string("hello")])])]))
        check(blockedPasteMCP?["result"]["isError"] == .bool(true), "MCP clipboardPaste proposal blocked")
        check(try AgentMCPBridge.decodeAction(.object(["kind": .string("clipboardRead")])) == .clipboardRead, "clipboardRead decoded")
        check(try AgentMCPBridge.decodeAction(.object(["kind": .string("clipboardUndo")])) == .clipboardUndo, "clipboardUndo decoded")
        check(try AgentMCPBridge.decodeAction(.object(["kind": .string("clipboardWrite"), "text": .string("Translated")])) == .clipboardWrite("Translated"), "clipboardWrite decoded")
        let clock = ApprovalClock()
        let expiring = AgentActionBroker(executor: executor, uptime: { clock.read() })
        let expiryTurn = UUID(); await expiring.begin(turn: expiryTurn, language: "en")
        let expires = try await expiring.propose(.openApp("terminal"), turn: expiryTurn)
        let expiryToken = try await expiring.approve(plan: expires.id)
        clock.set(121)
        do { _ = try await expiring.commit(plan: expires.id, token: expiryToken); fatalError("Expired approval") }
        catch ApprovalError.expired { count += 1 }
        check(await executor.count == 1, "Expired approval has no effect")
        print("Approval tests: \(count) checks passed")
    }
}
actor RecordingActionRunner: TypedActionRunning {
    private(set) var count = 0
    func run(_ action: Action, language: String) async -> CommandOutcome { count += 1; return .done(summary: "ok") }
}

final class ApprovalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}
