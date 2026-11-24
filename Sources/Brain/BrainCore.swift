import Foundation

// Pure parts of Jarvis's brain: OpenAI Chat Completions stream parsing, cost,
// streaming sentence splitting and short conversation memory. No network,
// no AppKit, so all of it is unit-tested without an API key.

/// Token usage of one model round (Chat Completions `usage`).
struct BrainUsage: Equatable {
    var prompt = 0, cached = 0, completion = 0

    static func + (a: BrainUsage, b: BrainUsage) -> BrainUsage {
        BrainUsage(prompt: a.prompt + b.prompt, cached: a.cached + b.cached, completion: a.completion + b.completion)
    }

    /// gpt-5.4-mini price, OpenAI model page (checked 24.11.2026): $0.75 per 1M
    /// input tokens, $0.075 cached input, $4.50 output. One token at $X per 1M
    /// costs exactly X micro-dollars, so the sum is already in micros.
    static let inputMicros = 0.75, cachedMicros = 0.075, outputMicros = 4.5

    var costMicros: Int64 {
        let fresh = Double(max(0, prompt - cached))
        let total = fresh * Self.inputMicros + Double(cached) * Self.cachedMicros + Double(completion) * Self.outputMicros
        return Int64(total.rounded(.up))
    }
}

/// One `data:` event of a streamed chat completion.
struct BrainDelta: Equatable {
    struct ToolPiece: Equatable { var index: Int; var id: String?; var name: String?; var arguments: String? }
    var content = ""
    var tools: [ToolPiece] = []
    var usage: BrainUsage?
    var finish: String?
}

enum BrainEvent: Equatable { case delta(BrainDelta), done }

enum BrainSSE {
    /// nil for comments, blank lines and unparsable data (skipped, never fatal).
    static func parse(_ line: String) -> BrainEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var delta = BrainDelta()
        if let usage = object["usage"] as? [String: Any] {
            let details = usage["prompt_tokens_details"] as? [String: Any]
            delta.usage = BrainUsage(prompt: usage["prompt_tokens"] as? Int ?? 0,
                                     cached: details?["cached_tokens"] as? Int ?? 0,
                                     completion: usage["completion_tokens"] as? Int ?? 0)
        }
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            delta.finish = choice["finish_reason"] as? String
            let body = choice["delta"] as? [String: Any] ?? [:]
            delta.content = body["content"] as? String ?? ""
            for call in body["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any]
                delta.tools.append(.init(index: call["index"] as? Int ?? 0, id: call["id"] as? String,
                                         name: function?["name"] as? String, arguments: function?["arguments"] as? String))
            }
        }
        return .delta(delta)
    }
}

/// Assembles tool calls whose id, name and arguments arrive in pieces.
struct BrainToolAssembler {
    struct Call: Equatable { var id = "", name = "", arguments = "" }
    private(set) var calls: [Int: Call] = [:]

    mutating func add(_ pieces: [BrainDelta.ToolPiece]) {
        for piece in pieces {
            var call = calls[piece.index] ?? Call()
            if let id = piece.id, !id.isEmpty { call.id = id }
            if let name = piece.name, !name.isEmpty { call.name += name }
            if let arguments = piece.arguments { call.arguments += arguments }
            calls[piece.index] = call
        }
    }

    var ordered: [Call] { calls.keys.sorted().compactMap { calls[$0] } }
}

/// Emits whole spoken sentences while text streams in. A sentence ends at
/// . ! ? … followed by whitespace (so "41.5" and "14:05" stay whole) or at a
/// line break. Markdown symbols are dropped; speech stops after `limit` chars.
struct SentenceStreamer {
    var limit: Int
    init(limit: Int = 240) { self.limit = limit }
    private var buffer = ""
    private(set) var spokenCount = 0
    private(set) var all = ""
    private var stopped = false

    mutating func feed(_ text: String) -> [String] {
        let clean = text.filter { !"*#`_>".contains($0) }
        all += clean
        var out: [String] = []
        for c in clean {
            if c == "\n" { out += take(); continue }
            if let last = buffer.last, ".!?…".contains(last), c.isWhitespace { out += take() }
            buffer.append(c)
        }
        return out
    }

    mutating func finish() -> [String] { take() }

    private mutating func take() -> [String] {
        let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !piece.isEmpty, !stopped else { return [] }
        // Once a sentence does not fit, later ones are not spoken either:
        // skipping one would make the spoken text incoherent.
        guard spokenCount + piece.count <= limit || spokenCount == 0 else { stopped = true; return [] }
        let sentence = String(piece.prefix(limit))
        spokenCount += sentence.count
        return [sentence]
    }
}

/// Last few exchanges, so "закрий його" knows what "його" is. Lives only in
/// RAM: cleared on app restart, microphone off and after a quiet pause, so a
/// stale reference cannot pick the wrong target.
struct BrainMemory {
    var maxTurns: Int
    var idleSeconds: TimeInterval
    init(maxTurns: Int = 8, idleSeconds: TimeInterval = 300) { self.maxTurns = maxTurns; self.idleSeconds = idleSeconds }
    private(set) var turns: [[[String: Any]]] = []
    private var lastUsed: Date?

    mutating func messages(now: Date = Date()) -> [[String: Any]] {
        if let lastUsed, now.timeIntervalSince(lastUsed) > idleSeconds { turns.removeAll() }
        return turns.flatMap { $0 }
    }

    /// A whole turn (user, assistant/tool calls, tool results, final assistant)
    /// is kept or dropped together, so the history stays valid for the API.
    mutating func append(turn: [[String: Any]], now: Date = Date()) {
        guard !turn.isEmpty else { return }
        turns.append(turn)
        // Drop half at once, not one turn at a time: the remaining history then
        // stays an identical prefix for several requests and OpenAI keeps it
        // cached (one-at-a-time trimming made every request a cache miss).
        if turns.count > maxTurns { turns.removeFirst(turns.count - max(1, maxTurns / 2)) }
        lastUsed = now
    }

    mutating func clear() { turns.removeAll(); lastUsed = nil }
}
