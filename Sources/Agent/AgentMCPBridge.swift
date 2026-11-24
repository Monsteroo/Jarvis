import Foundation

/// Legacy MCP request handler, suitable for an app-owned IPC bridge. Planning only.
/// Do not instantiate a separate executor in the Goose child process.
actor AgentMCPBridge {
    let broker: AgentActionBroker
    let turn: UUID
    private var initialized = false
    private var closed = false
    func close() { closed = true }
    init(broker: AgentActionBroker, turn: UUID) { self.broker = broker; self.turn = turn }
    func handle(_ message: JSONValue) async -> JSONValue? {
        let id = message["id"]
        guard !closed, !Task.isCancelled else { return error(id, code: -32600) }
        guard message["jsonrpc"].string == "2.0", let method = message["method"].string else {
            return error(id, code: -32600)
        }
        if id == .null { return nil }
        switch method {
        case "server/discover": return error(id, code: -32601)
        case "initialize":
            guard message["params"]["protocolVersion"].string == "2025-11-25" else { return error(id, code: -32602) }
            initialized = true
            return result(id, .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("jarvis-plans"), "version": .string("0.1")])]))
        case "ping": return result(id, .object([:]))
        case "tools/list":
            guard initialized else { return error(id, code: -32600) }
            return result(id, .object(["tools": .array([.object([
                "name": .string("propose_action"), "description": .string("Propose one typed local action for native Jarvis review. Does not execute it."),
                "inputSchema": schema,
                "annotations": .object(["readOnlyHint": .bool(true), "destructiveHint": .bool(false)])])])]))
        case "tools/call":
            guard initialized else { return error(id, code: -32600) }
            do {
                guard message["params"]["name"].string == "propose_action" else { throw AgentError.invalidMessage }
                let action = try Self.decodeAction(message["params"]["arguments"])
                let plan = try await broker.propose(action, turn: turn)
                return toolResult(id, text: "Plan \(plan.id.uuidString) awaits native user review. No action executed.", failed: false)
            } catch { return toolResult(id, text: "Proposal rejected. No action executed.", failed: true) }
        default: return error(id, code: -32601)
        }
    }
    private var schema: JSONValue {
        .object(["type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("kind")]), "properties": .object([
                "kind": .object(["type": .string("string"), "enum": .array(["openApp", "activateApp", "quitApp", "openURL", "webSearch", "windowMinimize", "windowMaximize", "windowLeftHalf", "windowRightHalf", "windowMinimizeAll", "volumeSet", "volumeStep", "mute"].map(JSONValue.string))]),
                "target": .object(["type": .string("string"), "maxLength": .number(2048)]),
                "value": .object(["type": .string("integer"), "minimum": .number(-100), "maximum": .number(100)]),
                "muted": .object(["type": .string("boolean")])])])
    }
    static func decodeAction(_ args: JSONValue) throws -> Action {
        guard case .object(let fields) = args, let kind = args["kind"].string else { throw AgentError.invalidMessage }
        let action: Action, allowed: Set<String>
        switch kind {
        case "openApp", "activateApp", "quitApp", "openURL", "webSearch":
            allowed = ["kind", "target"]
            guard let target = args["target"].string else { throw AgentError.invalidMessage }
            switch kind { case "openApp": action = .openApp(target); case "activateApp": action = .activateApp(target)
            case "quitApp": action = .quitApp(target); case "openURL": action = .openURL(target); default: action = .webSearch(target) }
        case "volumeSet", "volumeStep":
            allowed = ["kind", "value"]
            guard let value = args["value"].decimal, value >= -100, value <= 100 else { throw AgentError.invalidMessage }
            let integer = NSDecimalNumber(decimal: value).intValue
            guard Decimal(integer) == value else { throw AgentError.invalidMessage }
            action = kind == "volumeSet" ? .volumeSet(integer) : .volumeStep(integer)
        case "mute":
            allowed = ["kind", "muted"]
            guard case .bool(let muted) = args["muted"] else { throw AgentError.invalidMessage }; action = .mute(muted)
        default:
            allowed = ["kind"]
            switch kind { case "windowMinimize": action = .windowMinimize; case "windowMaximize": action = .windowMaximize
            case "windowLeftHalf": action = .windowLeftHalf; case "windowRightHalf": action = .windowRightHalf
            case "windowMinimizeAll": action = .windowMinimizeAll
            default: throw AgentError.invalidMessage }
        }
        guard Set(fields.keys) == allowed else { throw AgentError.invalidMessage }
        try ActionRegistry().validate(action)
        return action
    }
    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
    private func error(_ id: JSONValue, code: Int) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Decimal(code)), "message": .string("Request rejected")])]) }
    private func toolResult(_ id: JSONValue, text: String, failed: Bool) -> JSONValue {
        result(id, .object(["isError": .bool(failed), "content": .array([.object(["type": .string("text"), "text": .string(text)])])]))
    }
}
