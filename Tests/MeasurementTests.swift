import Foundation

@main
struct MeasurementTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func record(_ model: String, _ lang: String, pass: Int, index: Int) -> MeasurementRecord {
        MeasurementRecord(timestamp: "t", model: model, languageSetting: lang, pass: pass, promptIndex: index,
                          promptLanguage: "uk", expected: "e", transcript: "", status: .ok, timedOut: false,
                          audioSeconds: 1, whisperSeconds: 0.3, responseSeconds: 0.4)
    }

    static func main() throws {
        let prompts = PromptSet.parse("# comment\nuk|Відкрий Телеграм.\n\n en | Open Safari | now \nbroken line\n|empty\n")
        check(prompts == [Prompt(language: "uk", text: "Відкрий Телеграм."), Prompt(language: "en", text: "Open Safari | now")],
              "parse keeps lang|text lines and splits on the first bar")

        var progress = MeasurementProgress.next(records: [], model: "base", languageSetting: "uk", promptCount: 3)
        check(progress == MeasurementProgress(pass: 1, index: 0), "empty log starts at pass 1, first prompt")

        var records = [record("base", "uk", pass: 1, index: 0), record("base", "uk", pass: 1, index: 2),
                       record("small", "uk", pass: 1, index: 1), record("base", "auto", pass: 1, index: 1)]
        progress = MeasurementProgress.next(records: records, model: "base", languageSetting: "uk", promptCount: 3)
        check(progress == MeasurementProgress(pass: 1, index: 1), "gaps are filled; other model/language do not count")

        records.append(record("base", "uk", pass: 1, index: 1))
        progress = MeasurementProgress.next(records: records, model: "base", languageSetting: "uk", promptCount: 3)
        check(progress == MeasurementProgress(pass: 2, index: 0), "full pass moves to the next pass")

        for pass in 2...3 { for i in 0..<3 { records.append(record("base", "uk", pass: pass, index: i)) } }
        progress = MeasurementProgress.next(records: records, model: "base", languageSetting: "uk", promptCount: 3)
        check(progress.finished, "three passes finish the set")
        check(MeasurementProgress.next(records: [], model: "base", languageSetting: "uk", promptCount: 0).finished,
              "no prompts means nothing to measure")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-measure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = MeasurementLog(url: dir.appendingPathComponent("m.jsonl"))
        check(log.records().isEmpty, "missing log reads as empty")
        var first = record("base", "uk", pass: 1, index: 0)
        first.transcript = "Відкрий \"Телеграм\"\nдалі"
        try log.append(first)
        try log.append(record("small", "auto", pass: 2, index: 4))
        check(log.records() == [first, record("small", "auto", pass: 2, index: 4)], "JSONL round-trips, one record per line")
        let raw = try String(contentsOf: log.url, encoding: .utf8)
        check(raw.split(separator: "\n").count == 2 && raw.contains("\"language_setting\":\"uk\""), "snake_case keys, newline-safe")
        let mode = (try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600, "log is private to the user")

        // MeasurementSession: prompts and log under the project root, same strings as before.
        let root = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/benchmarks"), withIntermediateDirectories: true)
        let missing = MeasurementSession(projectRoot: dir.appendingPathComponent("none").path)
        let none = missing.refresh(model: "base", language: "uk")
        check(none.prompt == "Не знайдено docs/benchmarks/prompts.txt." && !none.canSkip && missing.current == nil, "session without prompts")
        try "uk|Відкрий Телеграм.\nen|Open Safari.\n".write(to: root.appendingPathComponent("docs/benchmarks/prompts.txt"), atomically: true, encoding: .utf8)
        let session = MeasurementSession(projectRoot: root.path)
        check(session.current == nil, "nothing is current before the first refresh")
        var state = session.refresh(model: "base", language: "uk")
        check(state.canSkip && state.prompt == "Прохід 1/3 · 1/2 · [uk] Відкрий Телеграм.", "first prompt: \(state.prompt)")
        check(session.current?.prompt.text == "Відкрий Телеграм.", "current prompt")
        for pass in 1...3 { for i in 0..<2 { try session.append(record("base", "uk", pass: pass, index: i)) } }
        state = session.refresh(model: "base", language: "uk")
        check(!state.canSkip && session.current == nil
              && state.prompt == "Усі 3 проходи для base / uk записано. Запустіть scripts/analyze_measurements.py.", "finished: \(state.prompt)")
        check(MeasurementLog(url: root.appendingPathComponent(".runtime/measurements/uk-en-v1.jsonl")).records().count == 6,
              "session writes to the historical log path")
        print("MeasurementTests: passed")
    }
}
