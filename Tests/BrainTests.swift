import Foundation

/// Scripted OpenAI responses: one entry per request (status + SSE lines).
final class FakeTransport: BrainTransport {
    var replies: [(Int, [String])]
    private(set) var bodies: [[String: Any]] = []
    init(_ replies: [(Int, [String])]) { self.replies = replies }
    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        if let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] { bodies.append(body) }
        let (status, lines) = replies.isEmpty ? (500, ["no more replies"]) : replies.removeFirst()
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

/// First call times out, then delegates.
final class FlakyTransport: BrainTransport {
    let then: FakeTransport
    private(set) var failures = 0
    init(then: FakeTransport) { self.then = then }
    func open(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        if failures == 0 { failures += 1; throw URLError(.timedOut) }
        return try await then.open(request)
    }
}

func text(_ s: String) -> String {
    let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": s]]]])
    return "data: " + String(data: json, encoding: .utf8)!
}
func tool(_ index: Int, id: String? = nil, name: String? = nil, args: String) -> String {
    var call: [String: Any] = ["index": index, "function": ["arguments": args] as [String: Any]]
    if let id { call["id"] = id; call["type"] = "function" }
    if let name { call["function"] = ["name": name, "arguments": args] }
    let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["tool_calls": [call]]]]])
    return "data: " + String(data: json, encoding: .utf8)!
}
func usage(_ prompt: Int, cached: Int = 0, _ completion: Int) -> String {
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":\(prompt),\"completion_tokens\":\(completion),\"prompt_tokens_details\":{\"cached_tokens\":\(cached)}}}"
}

@main struct BrainTests {
    static func main() async {
        var failures = 0, count = 0
        func check(_ ok: Bool, _ what: String) {
            count += 1
            if !ok { failures += 1; print("FAIL: \(what)") }
        }

        // SSE parsing.
        check(BrainSSE.parse("data: [DONE]") == .done, "done marker")
        check(BrainSSE.parse(": keep-alive") == nil && BrainSSE.parse("") == nil && BrainSSE.parse("data: {broken") == nil, "junk is skipped")
        if case .delta(let d)? = BrainSSE.parse(usage(1000, cached: 800, 50)) {
            check(d.usage == BrainUsage(prompt: 1000, cached: 800, completion: 50), "usage with cached tokens")
        } else { check(false, "usage chunk parsed") }

        // Cost: 200 fresh × 0.75 + 800 cached × 0.075 + 50 × 4.5 = 150 + 60 + 225 = 435 micros.
        check(BrainUsage(prompt: 1000, cached: 800, completion: 50).costMicros == 435, "cost in micro-dollars")
        check(BrainUsage(prompt: 1, cached: 0, completion: 0).costMicros == 1, "cost rounds up")

        // Tool call pieces assemble across chunks.
        var assembler = BrainToolAssembler()
        assembler.add([.init(index: 0, id: "c1", name: "run_action", arguments: "{\"kind\":")])
        assembler.add([.init(index: 0, id: nil, name: nil, arguments: "\"openApp\",\"target\":\"Calendar\"}")])
        assembler.add([.init(index: 1, id: "c2", name: "run_action", arguments: "{}")])
        check(assembler.ordered.count == 2 && assembler.ordered[0].arguments == "{\"kind\":\"openApp\",\"target\":\"Calendar\"}"
              && assembler.ordered[0].id == "c1", "split arguments joined in order")

        // Streaming sentences.
        var streamer = SentenceStreamer()
        var said = streamer.feed("Звісно, сер. Зараз 14:05 і курс 41.5")
        said += streamer.feed(" гривні. **Ще** одне")
        said += streamer.finish()
        check(said == ["Звісно, сер.", "Зараз 14:05 і курс 41.5 гривні.", "Ще одне"], "sentences stream whole: \(said)")
        var short = SentenceStreamer(limit: 20)
        let capped = short.feed("Перше речення. Друге довге речення тут. Третє.") + short.finish()
        check(capped == ["Перше речення."], "speech stops at the limit: \(capped)")

        // Memory keeps whole turns, forgets after a pause.
        var memory = BrainMemory(maxTurns: 2, idleSeconds: 300)
        let t0 = Date()
        memory.append(turn: [["role": "user", "content": "1"]], now: t0)
        memory.append(turn: [["role": "user", "content": "2"], ["role": "assistant", "content": "ok"]], now: t0)
        memory.append(turn: [["role": "user", "content": "3"]], now: t0)
        let kept = memory.messages(now: t0)
        let firstKept = kept.first?["content"] as? String
        check(kept.count == 1 && firstKept == "3", "old turns dropped whole, half at a time")
        check(memory.messages(now: t0.addingTimeInterval(301)).isEmpty, "idle pause clears memory")

        // Argument decoding uses the strict action schema.
        check(JarvisBrain.decode("{\"kind\":\"quitApp\",\"target\":\"Calendar\"}") == .quitApp("Calendar"), "decode quitApp")
        check(JarvisBrain.decode("{\"kind\":\"dictate\",\"target\":\"x\"}") == nil, "dictation is not a brain action")
        check(JarvisBrain.decode("{\"kind\":\"openApp\",\"target\":\"X\",\"extra\":1}") == nil, "extra fields rejected")
        check(JarvisBrain.decode("not json") == nil, "garbage rejected")
        check(JarvisBrain.addressed("Програму «Calendar» відкрито.", language: "uk") == "Програму «Calendar» відкрито, сер.", "summary addressed")
        check(JarvisBrain.addressed("Done, sir.", language: "en") == "Done, sir.", "no double address")

        await MainActor.run {} // hop for the @MainActor brain below
        await brainScenarios(check)

        print(failures == 0 ? "Brain tests passed (\(count))" : "Brain tests: \(failures) of \(count) failed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func brainScenarios(_ check: (Bool, String) -> Void) async {
        // 1. Plain answer: streamed, remembered, request shape.
        let plain = FakeTransport([(200, [text("Привіт, сер."), text(" Чим допомогти?"), usage(500, 20), "data: [DONE]"])])
        let brain = JarvisBrain(transport: plain, model: "gpt-5.4-mini")
        var sentences: [String] = []
        var executed: [Action] = []
        let result = try? await brain.respond(to: "Привіт", language: "uk", system: "SYS", context: "[ctx]", apiKey: "k",
                                              execute: { executed.append($0); return .executed(.done(summary: "ok")) },
                                              onSentence: { sentences.append($0) })
        check(result?.reply == "Привіт, сер. Чим допомогти?" && result?.spoken == nil && result?.rounds == 1, "plain answer")
        check(sentences == ["Привіт, сер.", "Чим допомогти?"], "plain answer spoken while streaming")
        let body = plain.bodies.first ?? [:]
        check(body["reasoning_effort"] as? String == "none" && body["stream"] as? Bool == true
              && (body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true, "fast streaming request")
        let sent = body["messages"] as? [[String: Any]] ?? []
        check(sent.first?["content"] as? String == "SYS" && sent.last?["content"] as? String == "[ctx]\n\nПривіт", "static system first, context with request")
        check(executed.isEmpty, "no action for a chat reply")

        // 2. Action only: executed once, no second model round, summary spoken.
        let act = FakeTransport([(200, [tool(0, id: "c1", name: "run_action", args: "{\"kind\":\"quitApp\","),
                                        tool(0, args: "\"target\":\"Calendar\"}"), usage(900, cached: 800, 20), "data: [DONE]"])])
        brain.memory.clear()
        let actBrain = JarvisBrain(transport: act, model: "m")
        executed = []
        let acted = try? await actBrain.respond(to: "закрий календар", language: "uk", system: "S", context: "", apiKey: "k",
                                                execute: { executed.append($0); return .executed(.done(summary: "Програму «Calendar» закрито.")) },
                                                onSentence: { _ in })
        check(executed == [.quitApp("Calendar")], "action executed once")
        check(acted?.rounds == 1 && act.bodies.count == 1, "no second round after success")
        check(acted?.spoken == "Програму «Calendar» закрито, сер.", "real result is spoken")
        check(acted?.usage.cached == 800, "usage recorded")

        // 3. Memory: the next request carries the previous turn (tool call + result).
        let follow = FakeTransport([(200, [text("Готово."), usage(10, 1), "data: [DONE]"])])
        let memoryBrain = JarvisBrain(transport: follow, model: "m")
        memoryBrain.memory = actBrain.memory
        _ = try? await memoryBrain.respond(to: "відкрий його знову", language: "uk", system: "S", context: "", apiKey: "k",
                                           execute: { _ in .executed(.done(summary: "")) }, onSentence: { _ in })
        let roles = (follow.bodies.first?["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
        check(roles == ["system", "user", "assistant", "tool", "assistant", "user"], "previous turn remembered: \(roles)")

        // 4. Failure: the model sees it and explains in a second round.
        let fail = FakeTransport([
            (200, [tool(0, id: "c1", name: "run_action", args: "{\"kind\":\"openApp\",\"target\":\"Foo\"}"), usage(10, 1), "data: [DONE]"]),
            (200, [text("Не знайшов такої програми, сер."), usage(10, 1), "data: [DONE]"]),
        ])
        let failBrain = JarvisBrain(transport: fail, model: "m")
        sentences = []
        let failed = try? await failBrain.respond(to: "відкрий фу", language: "uk", system: "S", context: "", apiKey: "k",
                                                  execute: { _ in .executed(.failed(reason: "Програму «Foo» не знайдено.")) },
                                                  onSentence: { sentences.append($0) })
        check(failed?.rounds == 2 && sentences == ["Не знайшов такої програми, сер."] && failed?.spoken == nil, "failure explained by the model")
        let secondRoles = (fail.bodies.last?["messages"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
        check(secondRoles.suffix(2) == ["assistant", "tool"], "tool result goes back to the model")

        // 5. Invalid arguments never execute.
        let bad = FakeTransport([
            (200, [tool(0, id: "c1", name: "run_action", args: "{\"kind\":\"dictate\",\"target\":\"rm -rf\"}"), "data: [DONE]"]),
            (200, [text("Перепрошую, сер."), "data: [DONE]"]),
        ])
        executed = []
        let badResult = try? await JarvisBrain(transport: bad, model: "m").respond(
            to: "x", language: "uk", system: "S", context: "", apiKey: "k",
            execute: { executed.append($0); return .executed(.done(summary: "")) }, onSentence: { _ in })
        check(executed.isEmpty && badResult?.usageComplete == false, "invalid action not executed; unknown usage flagged")

        // 6. At most 3 actions per request.
        let many = FakeTransport([(200, (0..<5).map { tool($0, id: "c\($0)", name: "run_action", args: "{\"kind\":\"windowMinimize\"}") } + ["data: [DONE]"]),
                                  (200, [text("Забагато, сер."), "data: [DONE]"])])
        executed = []
        _ = try? await JarvisBrain(transport: many, model: "m").respond(
            to: "x", language: "uk", system: "S", context: "", apiKey: "k",
            execute: { executed.append($0); return .executed(.done(summary: "ok")) }, onSentence: { _ in })
        check(executed.count == 3, "tool calls capped at 3")

        // 7. HTTP errors surface; reasoning_effort rejection retries once without it.
        let denied = FakeTransport([(401, ["{\"error\":\"bad key\"}"])])
        do {
            _ = try await JarvisBrain(transport: denied, model: "m").respond(to: "x", language: "uk", system: "S", context: "", apiKey: "k",
                                                                             execute: { _ in .proposed }, onSentence: { _ in })
            check(false, "401 must throw")
        } catch let error as BrainError {
            if case .http(let status, _) = error { check(status == 401, "401 reported") } else { check(false, "401 kind") }
        } catch { check(false, "401 error type") }
        let retry = FakeTransport([(400, ["{\"error\":{\"param\":\"reasoning_effort\"}}"]), (200, [text("Так, сер."), "data: [DONE]"])])
        let retryBrain = JarvisBrain(transport: retry, model: "other")
        let retried = try? await retryBrain.respond(to: "x", language: "uk", system: "S", context: "", apiKey: "k",
                                                    execute: { _ in .proposed }, onSentence: { _ in })
        check(retried?.reply == "Так, сер." && !retryBrain.sendsReasoning && retry.bodies.last?["reasoning_effort"] == nil,
              "reasoning_effort dropped after a 400")

        // 7b. A stuck connection is retried once.
        let flaky = FlakyTransport(then: FakeTransport([(200, [text("Так, сер."), "data: [DONE]"])]))
        let recovered = try? await JarvisBrain(transport: flaky, model: "m").respond(to: "x", language: "uk", system: "S", context: "", apiKey: "k",
                                                                                   execute: { _ in .proposed }, onSentence: { _ in })
        check(recovered?.reply == "Так, сер." && flaky.failures == 1, "timeout retried once")

        // 8. Cancellation stops before any action.
        let slow = FakeTransport([(200, [tool(0, id: "c1", name: "run_action", args: "{\"kind\":\"windowMinimize\"}"), "data: [DONE]"])])
        executed = []
        let task = Task { @MainActor in
            try await JarvisBrain(transport: slow, model: "m").respond(to: "x", language: "uk", system: "S", context: "", apiKey: "k",
                                                                      execute: { executed.append($0); return .executed(.done(summary: "")) },
                                                                      onSentence: { _ in })
        }
        task.cancel()
        _ = try? await task.value
        check(executed.isEmpty, "cancelled request runs no action")

        // 9. Persona: brain prompt is static and bilingual-safe.
        let uk = AgentPersona.brainSystem(language: "uk", installedApps: ["Calendar", "Antigravity"])
        check(uk.contains("«сер»") && uk.contains("run_action") && uk.contains("Calendar, Antigravity") && !uk.contains("2026"), "uk brain prompt static")
        check(uk.contains("час в інших містах обчислюй сам"), "uk brain works out other time zones")
        check(uk.contains("закрити вкладку чи відео — це не закрити браузер") && uk.contains("в одну відповідь"), "uk brain: no bigger substitute, actions together")
        let en = AgentPersona.brainSystem(language: "en", installedApps: [])
        check(en.contains("\"sir\"") && en.contains("English only") && !en.contains("сер"), "en brain prompt")
        check(!uk.lowercased().contains("росій") && !en.lowercased().contains("russian"), "no third language")
        let context = AgentPersona.brainContext(language: "uk", apps: "Відкриті програми: Safari.",
                                                now: ISO8601DateFormatter().date(from: "2026-11-24T13:05:00Z")!,
                                                timeZone: TimeZone(identifier: "Europe/Kyiv")!)
        check(context.contains("2026-11-24 15:05") && context.contains("UTC+02:00") && context.contains("Safari"), "dynamic context")

        check(uk.contains("відповідай у годинах і хвилинах") && uk.contains("просто погодься"), "uk brain counts carefully")
        check(uk.contains("назви результат уголос") && uk.contains("спотворює слова"), "uk brain answers itself, tolerates ASR")
        check(en.contains("two run_action calls") && en.contains("garbles words"), "en brain two calls, ASR")
        check(uk.contains("«згорни всі вікна» чи «згорни все» — windowMinimizeAll") && en.contains("windowMinimizeAll"), "minimize all in prompt")
        check(JarvisBrain.decode("{\"kind\":\"windowMinimizeAll\"}") == .windowMinimizeAll, "brain decodes minimize all")
        check(JarvisBrain.decode("{\"kind\":\"windowMinimizeAll\",\"target\":\"x\"}") == nil, "minimize all takes no target")

        // 9b. Thinking only for counting and time questions (live failures 24.11.2026).
        for phrase in ["Скільки буде два плюс сім?", "Скільки хвилин залишилося до восьмої нульнуль?",
                       "Сек ти порахував.", "То до 20 години залишилося 2 години 19 хвилин.",
                       "Порахуй два плюс два на калькуляйтер.", "What is twenty percent of fifty?", "How many minutes until 8 pm?"] {
            check(JarvisBrain.needsThinking(phrase), "thinks: \(phrase)")
        }
        for phrase in ["Відкрий календар.", "Згорни Google Chrome.", "Як справи?", "Закрий останню вкладку.",
                       "Open Safari.", "Мені зараз однаково."] {
            check(!JarvisBrain.needsThinking(phrase), "fast path: \(phrase)")
        }
        let thinkBody = JarvisBrain(transport: FakeTransport([]), model: "m").body([], thinking: true)
        let fastBody = JarvisBrain(transport: FakeTransport([]), model: "m").body([])
        check(thinkBody["reasoning_effort"] as? String == "low" && thinkBody["max_completion_tokens"] as? Int == 1500, "thinking body")
        check(fastBody["reasoning_effort"] as? String == "none" && fastBody["max_completion_tokens"] as? Int == 400, "fast body")

        // 10. Local name resolution for the fallback.
        check(MacContext.resolvable("Terminal", installed: ["Terminal"], running: [], aliases: []), "installed name resolves")
        check(MacContext.resolvable("термінал", installed: [], running: [], aliases: ["термінал"]), "alias resolves")
        check(!MacContext.resolvable("ютуб в хромі", installed: ["Google Chrome"], running: [], aliases: []), "phrase does not resolve")
        check(!MacContext.resolvable("календар", installed: ["Calendar"], running: [], aliases: []), "Ukrainian name goes to the brain")

        // 11. UI AX loop: uiSnapshot continues to next round, allows >3 UI button presses,
        // never speaks raw snapshot XML, and strips snapshot payload from BrainMemory.
        let fencedSnap1 = UISnapshotText.fence(snapshotID: "abcd1234", body: "# snapshot\ne1 AXStaticText \"0\" [read]\ne2 AXButton \"2\" [press]\ne3 AXButton \"+\" [press]\ne4 AXButton \"=\" [press]")
        let fencedSnap2 = UISnapshotText.fence(snapshotID: "abcd5678", body: "# snapshot\ne1 AXStaticText \"4\" [read]")
        let calcTransport = FakeTransport([
            (200, [tool(0, id: "s1", name: "run_action", args: "{\"kind\":\"uiSnapshot\",\"target\":\"Calculator\"}"), usage(100, 10), "data: [DONE]"]),
            (200, [
                tool(0, id: "p1", name: "run_action", args: "{\"kind\":\"uiPress\",\"target\":\"Calculator\",\"snapshot\":\"abcd1234\",\"ref\":\"e2\"}"),
                tool(1, id: "p2", name: "run_action", args: "{\"kind\":\"uiPress\",\"target\":\"Calculator\",\"snapshot\":\"abcd1234\",\"ref\":\"e3\"}"),
                tool(2, id: "p3", name: "run_action", args: "{\"kind\":\"uiPress\",\"target\":\"Calculator\",\"snapshot\":\"abcd1234\",\"ref\":\"e2\"}"),
                tool(3, id: "p4", name: "run_action", args: "{\"kind\":\"uiPress\",\"target\":\"Calculator\",\"snapshot\":\"abcd1234\",\"ref\":\"e4\"}"),
                tool(4, id: "s2", name: "run_action", args: "{\"kind\":\"uiSnapshot\",\"target\":\"Calculator\"}"),
                usage(200, 30), "data: [DONE]",
            ]),
            (200, [text("Чотири, сер."), usage(180, 8), "data: [DONE]"]),
        ])
        let calcBrain = JarvisBrain(transport: calcTransport, model: "gpt-5.4-mini")
        var calcSentences: [String] = []
        var snapCallIndex = 0
        var calcActions: [Action] = []
        let calcRes = try? await calcBrain.respond(
            to: "Порахуй 2 + 2 на калькуляторі", language: "uk", system: "S", context: "", apiKey: "k",
            execute: { action in
                calcActions.append(action)
                if case .uiSnapshot = action {
                    snapCallIndex += 1
                    return .executed(.done(summary: snapCallIndex == 1 ? fencedSnap1 : fencedSnap2))
                }
                return .executed(.done(summary: "Натиснуто"))
            },
            onSentence: { calcSentences.append($0) }
        )
        check(calcRes?.rounds == 3 && calcActions.count == 6, "3-round UI observation-act-verify loop ran 6 UI tool calls")
        check(calcSentences == ["Чотири, сер."] && calcRes?.spoken == nil, "Only final verified answer is spoken, never raw snapshot")
        let storedMsgs = calcBrain.memory.messages()
        let leakedSnapshot = storedMsgs.contains { ($0["content"] as? String)?.contains("UNTRUSTED_UI_SNAPSHOT_") == true }
        check(!leakedSnapshot, "Raw UI snapshots redacted from BrainMemory after turn")

        // 12. Proposed UI action after snapshot stops and announces confirmation on screen;
        // uiSetValue masks sensitive text in result.actions log.
        let confirmTransport = FakeTransport([
            (200, [tool(0, id: "s1", name: "run_action", args: "{\"kind\":\"uiSnapshot\",\"target\":\"Notes\"}"), "data: [DONE]"]),
            (200, [tool(0, id: "w1", name: "run_action", args: "{\"kind\":\"uiSetValue\",\"target\":\"Notes\",\"snapshot\":\"abcd1234\",\"ref\":\"e1\",\"text\":\"Secret note body\"}"), "data: [DONE]"]),
        ])
        let confirmRes = try? await JarvisBrain(transport: confirmTransport, model: "m").respond(
            to: "Запиши в нотатки", language: "uk", system: "S", context: "", apiKey: "k",
            execute: { action in
                if case .uiSnapshot = action { return .executed(.done(summary: fencedSnap1)) }
                return .proposed
            },
            onSentence: { _ in }
        )
        check(confirmRes?.rounds == 2 && confirmRes?.spoken == "Чекає вашого підтвердження на екрані, сер.", "Proposed UI write announces confirmation")
        let actionLogs = confirmRes?.actions.map(\.action).joined(separator: " ") ?? ""
        check(!actionLogs.contains("Secret note body") && actionLogs.contains("<redacted>"), "uiSetValue text redacted in action logs")
    }
}
