import Foundation

struct GooseAnswer { let text: String; let cost: Money?; let stopReason: String }
struct GooseStreamEvent: Sendable {
    let turnID: UUID
    enum Kind: Sendable { case text(String), usage(Money), permissionRejected }
    let kind: Kind
}

/// Pinned ACP v1 subset. No files, terminal, audio, images, mode auto, or persistent grants.
actor GooseACPClient {
    private let transport: JSONRPCProcess
    private var session: String?
    private var active: UUID?
    private var text = ""
    private var cost: Money?
    private var invalidUsage = false
    private var ceiling: Money?
    private var listeners: [UUID: AsyncStream<GooseStreamEvent>.Continuation] = [:]
    init(transport: JSONRPCProcess) { self.transport = transport }
    func stream() -> AsyncStream<GooseStreamEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func emit(_ kind: GooseStreamEvent.Kind) {
        guard let active else { return }
        for continuation in listeners.values { continuation.yield(GooseStreamEvent(turnID: active, kind: kind)) }
    }
    func initialize(cwd: URL) async throws -> String {
        guard session == nil, cwd.isFileURL else { throw AgentError.invalidConfiguration }
        await transport.setHandler { [weak self] message in await self?.receive(message) }
        let initialized = try await transport.request("initialize", .object([
            "protocolVersion": .number(1), "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)]),
            "clientInfo": .object(["name": .string("jarvis"), "version": .string("0.1")])]))
        guard initialized["protocolVersion"].decimal == 1 else { throw AgentError.invalidMessage }
        let created = try await transport.request("session/new", .object(["cwd": .string(cwd.path), "mcpServers": .array([])]))
        guard let id = created["sessionId"].string, !id.isEmpty, id.count <= 256 else { throw AgentError.invalidMessage }
        session = id
        _ = try await transport.request("session/set_mode", .object(["sessionId": .string(id), "modeId": .string("approve")]))
        return id
    }
    func setCostCeiling(_ value: Money) { ceiling = value }
    func reportedCost() -> Money? { cost }
    func prompt(_ input: String, timeout: TimeInterval = 60) async throws -> GooseAnswer {
        guard let session else { throw AgentError.unavailable }
        guard active == nil else { throw AgentError.busy }
        guard !input.isEmpty, input.count <= 16_000 else { throw AgentError.invalidMessage }
        active = UUID(); text = ""; cost = nil; invalidUsage = false
        defer { active = nil }
        do {
            let result = try await transport.request("session/prompt", .object([
                "sessionId": .string(session), "prompt": .array([.object(["type": .string("text"), "text": .string(input)])])]), timeout: timeout)
            guard let reason = result["stopReason"].string, ["end_turn", "max_tokens", "max_turn_requests", "cancelled", "refusal"].contains(reason) else { throw AgentError.invalidMessage }
            guard reason != "cancelled" else { throw AgentError.cancelled }
            return GooseAnswer(text: text, cost: invalidUsage ? nil : cost, stopReason: reason)
        } catch {
            // Streamed chunks are provisional: caller must only commit text after successful result.
            text = ""; throw error
        }
    }
    func cancel() async {
        if let session { try? await transport.notify("session/cancel", .object(["sessionId": .string(session)])) }
        active = nil
        await transport.close()
    }
    func close() async {
        await cancel()
        for listener in listeners.values { listener.finish() }; listeners.removeAll()
    }
    private func receive(_ message: JSONValue) async {
        switch message["method"].string {
        case "session/update":
            guard active != nil, message["params"]["sessionId"].string == session else { return }
            let update = message["params"]["update"]
            switch update["sessionUpdate"].string {
            case "agent_message_chunk":
                guard update["content"]["type"].string == "text", let chunk = update["content"]["text"].string,
                      text.utf8.count + chunk.utf8.count <= 262_144 else { await transport.close(); return }
                text += chunk; emit(.text(chunk))
            case "usage_update":
                guard update["cost"] != .null else { return }
                guard update["cost"]["currency"].string == "USD", let decimal = update["cost"]["amount"].decimal,
                      let money = try? Money.usd(decimal), money >= (cost ?? .zero) else { invalidUsage = true; return }
                cost = money; emit(.usage(money)) // Cumulative session total, duplicate events do not add cost.
                if let ceiling, money >= ceiling { await cancel() }
            default: break
            }
        case "session/request_permission":
            guard message["id"] != .null else { return }
            let params = message["params"]
            var outcome: JSONValue = .object(["outcome": .string("cancelled")])
            if active != nil, params["sessionId"].string == session,
               let reject = params["options"].array?.first(where: { $0["kind"].string == "reject_once" }),
               let id = reject["optionId"].string {
                outcome = .object(["outcome": .string("selected"), "optionId": .string(id)])
            }
            try? await transport.respond(id: message["id"], result: .object(["outcome": outcome]))
            emit(.permissionRejected)
        default:
            if message["id"] != .null { try? await transport.reject(id: message["id"]) }
        }
    }
}
