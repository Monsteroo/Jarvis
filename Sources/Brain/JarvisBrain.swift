import Foundation

/// Jarvis's brain: one streamed OpenAI Chat Completions call per round, with
/// the typed Mac actions as a single tool, short memory and honest results.
/// Replaces the per-request Goose process for everyday voice requests
/// (owner decision D1, 24 November 2026); Goose stays for long tasks.
///
/// Only text goes out: the system prompt, recent exchanges, application names
/// and the request. Never audio, window titles or window contents.

enum BrainError: Error, Equatable {
    case http(Int, String)
    case noAnswer
}

protocol BrainTransport {
    /// HTTP status and the response body as lines.
    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

struct URLSessionBrainTransport: BrainTransport {
    /// One ephemeral session for the app lifetime: no cookies or disk cache,
    /// and the HTTP/2 connection is reused, which saves the TLS handshake.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await Self.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, lines)
    }
}

/// Used from the main thread only. `respond` runs on the main actor, so the
/// execute and onSentence callbacks may touch UI state directly.
final class JarvisBrain {
    enum ToolOutcome { case executed(CommandOutcome), proposed }

    struct Result {
        /// Everything the model wrote, for the screen and the log.
        var reply = ""
        /// Said after the streamed sentences: an action summary or failure.
        var spoken: String?
        var rounds = 0
        var actions: [(action: String, result: String)] = []
        var firstTextSeconds: Double?
        var usage = BrainUsage()
        /// false when a round ended without a usage chunk (cost unknown).
        var usageComplete = true
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let transport: BrainTransport
    var model: String
    var memory = BrainMemory()
    var maxRounds = 3
    var maxToolCalls = 3
    var maxUIRounds = 5
    var maxUIToolCalls = 8
    /// Cleared if the model rejects `reasoning_effort`; then it is omitted.
    private(set) var sendsReasoning = true
    private let clock: () -> TimeInterval

    init(transport: BrainTransport = URLSessionBrainTransport(), model: String,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.model = model
        self.clock = clock
    }

    /// `context` is the dynamic part (time, open applications) and goes with
    /// the request, so the static `system` prefix stays cacheable.
    /// `thinking`: brief hidden reasoning before the answer, for counting and
    /// time questions (see `needsThinking`). Without it gpt-5.4-mini answered
    /// "2 + 7" with "Сім" and 141 minutes as 21 (log, 24.11.2026).
    @MainActor func respond(to text: String, language: String, system: String, context: String, apiKey: String,
                 thinking: Bool = false,
                 execute: (Action) async -> ToolOutcome, onSentence: (String) -> Void) async throws -> Result {
        let en = language == "en"
        let history = memory.messages()
        var turn: [[String: Any]] = [["role": "user", "content": context.isEmpty ? text : context + "\n\n" + text]]
        var result = Result()
        var toolCalls = 0
        var uiToolCalls = 0
        var spokenChars = 0
        let started = clock()
        var roundLimit = maxRounds
        var round = 0

        while round < roundLimit {
            round += 1
            try Task.checkCancellation()
            result.rounds = round
            let messages: [[String: Any]] = [["role": "system", "content": system]] + history + turn
            let lines = try await openRound(messages, apiKey: apiKey, thinking: thinking)

            var streamer = SentenceStreamer(limit: max(0, 240 - spokenChars))
            var tools = BrainToolAssembler()
            var usage: BrainUsage?
            func emit(_ sentences: [String]) {
                for sentence in sentences { spokenChars += sentence.count; onSentence(sentence) }
            }
            for try await line in lines {
                try Task.checkCancellation()
                guard let event = BrainSSE.parse(line) else { continue }
                guard case .delta(let delta) = event else { break }
                if let value = delta.usage { usage = value }
                if !delta.content.isEmpty {
                    if result.firstTextSeconds == nil { result.firstTextSeconds = clock() - started }
                    emit(streamer.feed(delta.content))
                }
                tools.add(delta.tools)
            }
            try Task.checkCancellation()
            emit(streamer.finish())
            if let usage { result.usage = result.usage + usage } else { result.usageComplete = false }

            let text = streamer.all.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.reply += (result.reply.isEmpty ? "" : " ") + text }
            let calls = tools.ordered
            if calls.isEmpty {
                guard !text.isEmpty else { throw BrainError.noAnswer }
                turn.append(["role": "assistant", "content": text])
                memory.append(turn: Self.redactSnapshotsForMemory(turn))
                return result
            }

            turn.append(["role": "assistant", "content": text.isEmpty ? NSNull() : text,
                         "tool_calls": calls.map { ["id": $0.id, "type": "function",
                                                    "function": ["name": $0.name, "arguments": $0.arguments]] }])
            var summaries: [String] = [], failures: [String] = [], proposed = 0
            var sawSnapshot = false
            for call in calls {
                let toolText: String
                if call.name != "run_action" {
                    toolText = "Rejected: unknown tool. Nothing was executed."
                    failures.append(en ? "I could not tell which action to take, sir." : "Не зрозумів, яку дію виконати, сер.")
                } else if let action = Self.decode(call.arguments) {
                    let isUI = Self.isUIAction(action)
                    if isUI { roundLimit = max(roundLimit, maxUIRounds) }
                    if (!isUI && toolCalls >= maxToolCalls) || (isUI && uiToolCalls >= maxUIToolCalls) {
                        let cap = isUI ? maxUIToolCalls : maxToolCalls
                        toolText = "Skipped: at most \(cap) actions per request. Nothing was executed."
                        failures.append(en ? "That is more actions than I take at once, sir." : "Забагато дій за один раз, сер.")
                    } else {
                        if isUI { uiToolCalls += 1 } else { toolCalls += 1 }
                        let actionLabel = Self.safeActionLogLabel(action)
                        switch await execute(action) {
                        case .proposed:
                            proposed += 1
                            toolText = "Proposed. It awaits the owner's confirmation on screen; not executed yet."
                            result.actions.append((action: actionLabel, result: toolText))
                        case .executed(let outcome):
                            switch outcome {
                            case .done(let summary):
                                if case .uiSnapshot = action {
                                    sawSnapshot = true
                                    toolText = summary
                                    result.actions.append((action: actionLabel, result: "Done: snapshot (\(summary.count) chars)"))
                                } else if case .clipboardRead = action {
                                    sawSnapshot = true
                                    toolText = summary
                                    result.actions.append((action: actionLabel, result: "Done: clipboard (\(summary.count) chars)"))
                                } else {
                                    summaries.append(summary)
                                    toolText = "Done: \(summary)"
                                    result.actions.append((action: actionLabel, result: toolText))
                                }
                            case .partial(let summary, let details):
                                failures.append(summary + " " + details)
                                toolText = "Partly done: \(summary) \(details)"
                                result.actions.append((action: actionLabel, result: toolText))
                            case .failed(let reason):
                                failures.append(reason)
                                toolText = "Failed: \(reason)"
                                result.actions.append((action: actionLabel, result: toolText))
                            default:
                                failures.append(en ? "The action did not run." : "Дію не виконано.")
                                toolText = "Not executed."
                                result.actions.append((action: actionLabel, result: toolText))
                            }
                        }
                    }
                } else {
                    toolText = "Rejected: invalid arguments. Nothing was executed."
                    failures.append(en ? "I could not tell which action to take, sir." : "Не зрозумів, яку дію виконати, сер.")
                    result.actions.append((action: call.arguments, result: toolText))
                }
                turn.append(["role": "tool", "tool_call_id": call.id, "content": toolText])
            }
            try Task.checkCancellation()

            // Actions report their own outcome: no second model round when
            // everything went through (saves about a second), EXCEPT after
            // `uiSnapshot`, where the model must inspect the elements next.
            let continueAfterSnapshot = sawSnapshot && proposed == 0 && round < roundLimit
            if (!continueAfterSnapshot && failures.isEmpty) || round >= roundLimit {
                let say: String
                if let failure = failures.first {
                    say = failure
                } else if !summaries.isEmpty {
                    say = summaries.map { Self.addressed($0, language: language) }.joined(separator: " ")
                } else if proposed > 0 {
                    say = en ? "It awaits your confirmation on screen, sir." : "Чекає вашого підтвердження на екрані, сер."
                } else {
                    say = en ? "Done, sir." : "Готово, сер."
                }
                // The model already said "Opening Calendar, sir": a successful
                // result is shown, not repeated aloud.
                if !(failures.isEmpty && proposed == 0 && !text.isEmpty) { result.spoken = say }
                if result.reply.isEmpty { result.reply = say } else if result.spoken != nil { result.reply += " " + say }
                turn.append(["role": "assistant", "content": say])
                memory.append(turn: Self.redactSnapshotsForMemory(turn))
                return result
            }
        }
        throw BrainError.noAnswer
    }

    /// "Програму «Calendar» відкрито." → "Програму «Calendar» відкрито, сер."
    static func addressed(_ summary: String, language: String) -> String {
        let address = language == "en" ? "sir" : "сер"
        var text = summary.trimmingCharacters(in: .whitespaces)
        guard !text.lowercased().contains(address) else { return text }
        if let last = text.last, ".!".contains(last) { text.removeLast() }
        return text + ", " + address + "."
    }

    static func decode(_ arguments: String) -> Action? {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return try? AgentMCPBridge.decodeAction(value)
    }

    private func openRound(_ messages: [[String: Any]], apiKey: String, thinking: Bool) async throws -> AsyncThrowingStream<String, Error> {
        for attempt in 0..<2 {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body(messages, thinking: thinking))
            let status: Int, lines: AsyncThrowingStream<String, Error>
            do {
                (status, lines) = try await transport.open(request)
            } catch let error as URLError where attempt == 0 && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                // A stale or stuck connection (first request took 24 s on
                // 24.11.2026): one retry on a fresh attempt.
                continue
            }
            if status == 200 { return lines }
            var detail = ""
            for try await line in lines where detail.count < 2000 { detail += line }
            // gpt-5.4-mini accepts reasoning_effort "none" and "low" (model
            // page); if a configured model rejects it, retry once without and remember.
            if status == 400, attempt == 0, sendsReasoning, detail.contains("reasoning") {
                sendsReasoning = false
                continue
            }
            throw BrainError.http(status, String(detail.prefix(300)))
        }
        throw BrainError.noAnswer
    }

    func body(_ messages: [[String: Any]], thinking: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "messages": messages, "tools": [Self.tool], "tool_choice": "auto",
            "stream": true, "stream_options": ["include_usage": true],
            // Reasoning tokens count toward the limit: room for them when thinking.
            "max_completion_tokens": thinking ? 1500 : 400,
        ]
        if sendsReasoning { body["reasoning_effort"] = thinking ? "low" : "none" }
        return body
    }

    /// Counting, arithmetic and time-difference questions get brief reasoning;
    /// everything else (commands, chat) stays on the fastest path. Local and
    /// cheap: digits, number words and counting words, uk and en.
    static func needsThinking(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if lower.contains(where: { $0.isNumber }) { return true }
        let words = lower.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        let exact: Set<String> = [
            "нуль", "один", "одна", "одну", "два", "дві", "три", "сім", "сто", "двісті", "триста", "плюс", "мінус",
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "hundred", "thousand", "plus", "minus", "times", "percent", "half",
        ]
        let stems = [
            "скільк", "порах", "обчисл", "помнож", "множ", "поділ", "відсот", "різниц", "хвилин", "годин",
            "одинадцят", "дванадцят", "тринадцят", "сімнадцят", "чотир", "п'ят", "шіст", "вісім", "дев'ят",
            "десят", "двадцят", "тридцят", "сорок", "сімдесят", "дев'яност", "сотн", "тисяч", "мільйон", "мільярд", "половин",
            "calculat", "minute", "hour", "divid", "multipl", "twenty", "thirty", "forty", "fifty",
        ]
        if words.contains(where: { exact.contains($0) }) { return true }
        if words.contains(where: { word in stems.contains { word.hasPrefix($0) } }) { return true }
        return lower.contains("how many") || lower.contains("how much") || lower.contains("how long")
    }

    private static func isUIAction(_ action: Action) -> Bool {
        switch action {
        case .uiSnapshot, .uiPress, .uiSetValue: return true
        default: return false
        }
    }

    private static func safeActionLogLabel(_ action: Action) -> String {
        switch action {
        case .uiSetValue(let app, let snapshotID, let ref, _):
            return "uiSetValue(app: \"\(app)\", snapshotID: \"\(snapshotID)\", ref: \"\(ref)\", text: <redacted>)"
        case .clipboardWrite(let text):
            return "clipboardWrite(text: <redacted, \(text.count) chars>)"
        case .clipboardPaste(let text):
            return "clipboardPaste(text: <redacted, \(text.count) chars>)"
        default:
            return "\(action)"
        }
    }

    private static func redactSnapshotsForMemory(_ turn: [[String: Any]]) -> [[String: Any]] {
        turn.map { message in
            guard message["role"] as? String == "tool",
                  let content = message["content"] as? String,
                  content.contains("<UNTRUSTED_UI_SNAPSHOT_") else {
                return message
            }
            var copy = message
            copy["content"] = "[UI snapshot omitted after turn]"
            return copy
        }
    }

    /// Same typed schema as the Goose MCP tool; arguments are checked by
    /// `AgentMCPBridge.decodeAction` and `ActionRegistry`. Dictation is absent.
    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run_action",
            "description": """
            Run one action on the owner's Mac. kind and fields: openApp/activateApp/quitApp {target: exact application name \
            from the installed list}; openURL {target: full https URL, opens in the default browser}; webSearch {target: query}; \
            windowMinimize/windowMaximize/windowLeftHalf/windowRightHalf {} act on the front window; \
            windowMinimizeAll {} minimizes every window of every application; \
            tabCloseActive/tabCloseLast {optional target: browser name} close the active or rightmost browser tab; \
            tabNew {optional target: browser name} opens a new browser tab; noteNew {} creates a new note in Notes; \
            mediaPlayPause {} presses the play/pause media key (pauses or resumes a video in the browser, or music); \
            tabSelect {value: 1…9} switches to browser tab N, 9 = the last tab; tabReopen {} reopens the last closed tab; \
            tabPrevious {} / tabNext {} switch to the tab left / right of the current one; \
            uiSnapshot {optional target: application name} reads accessible window elements with a snapshot id and e1…eN refs; \
            uiPress {target: application name, snapshot: snapshot id, ref: eN} presses an element from a fresh uiSnapshot; \
            uiSetValue {target: application name, snapshot: snapshot id, ref: eN, text: value} writes text into a field without sending; \
            runShortcut {target: exact name from the owner's allowed Apple Shortcuts list} runs an allowlisted macOS Shortcut; \
            clipboardRead {} reads masked clipboard text (up to 8000 chars); \
            clipboardWrite {text: value} copies text to the clipboard; \
            clipboardUndo {} restores the previous clipboard entry; \
            clipboardPaste {text: value} copies and inserts text into the active field (awaits confirmation); \
            volumeSet {value: 0…100}; volumeStep {value: -100…100}; mute {muted: true|false}. Call it once per action, in order.
            """,
            "parameters": [
                "type": "object", "additionalProperties": false, "required": ["kind"],
                "properties": [
                    "kind": ["type": "string", "enum": [
                        "openApp", "activateApp", "quitApp", "openURL", "webSearch",
                        "windowMinimize", "windowMaximize", "windowLeftHalf", "windowRightHalf", "windowMinimizeAll",
                        "tabCloseActive", "tabCloseLast", "uiSnapshot", "uiPress", "uiSetValue",
                        "tabNew", "noteNew", "mediaPlayPause", "tabSelect", "tabReopen", "tabPrevious", "tabNext",
                        "runShortcut",
                        "clipboardRead", "clipboardWrite", "clipboardUndo", "clipboardPaste",
                        "volumeSet", "volumeStep", "mute"
                    ]],
                    "target": ["type": "string", "maxLength": 2048],
                    "snapshot": ["type": "string", "maxLength": 32],
                    "ref": ["type": "string", "maxLength": 8],
                    "text": ["type": "string", "maxLength": 16000],
                    "value": ["type": "integer", "minimum": -100, "maximum": 100],
                    "muted": ["type": "boolean"],
                ],
            ] as [String: Any],
        ] as [String: Any],
    ]
}
