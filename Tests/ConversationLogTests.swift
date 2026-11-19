import Foundation

@main struct ConversationLogTests {
 static func main() {
    var failures = 0, count = 0
    func check(_ ok: Bool, _ what: String) {
        count += 1
        if !ok { failures += 1; print("FAIL: \(what)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-log-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var uptime: TimeInterval = 100
    var date = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
    let log = ConversationLog(directory: root, enabled: true, clock: { uptime }, now: { date })

    func lines() -> [[String: Any]] {
        log.flush()
        return ConversationLog.files(in: root).flatMap { file -> [[String: Any]] in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    // Events of one turn, with seconds since the owner stopped speaking.
    log.beginTurn(7, at: 100)
    uptime = 100.42
    log.record("heard", ["raw": "Котра година в Токіо?", "language": "uk"])
    uptime = 103.9
    log.record("agent", ["reply": "Зараз 0:05, сер."])
    var all = lines()
    check(all.count == 2, "two lines")
    check(all.first?["event"] as? String == "heard", "event name")
    check(all.first?["raw"] as? String == "Котра година в Токіо?", "Ukrainian text kept verbatim")
    check(all.first?["turn"] as? Int == 7, "turn id")
    check(abs((all.first?["t"] as? Double ?? 0) - 0.42) < 0.001, "t since speech end")
    check(abs((all.last?["t"] as? Double ?? 0) - 3.9) < 0.001, "t later")
    check((all.first?["session"] as? String)?.count == 8, "session id")

    // Private files.
    let file = ConversationLog.files(in: root).first!
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
    check(mode == 0o600, "file is 0600 (got \(String(mode, radix: 8)))")
    let dirMode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int) ?? 0
    check(dirMode == 0o700, "directory is 0700")
    check(file.lastPathComponent == "2026-11-10.jsonl", "one file per day")

    // Off means nothing is written.
    log.enabled = false
    log.record("heard", ["raw": "secret"])
    log.enabled = true
    check(lines().count == 2, "disabled log writes nothing")

    // Retention: old days are pruned, recent kept.
    date = ISO8601DateFormatter().date(from: "2026-12-20T12:00:00Z")!
    log.record("heard", ["raw": "later"])
    log.prune()
    all = lines()
    check(ConversationLog.files(in: root).map(\.lastPathComponent) == ["2026-12-20.jsonl"], "files older than 30 days pruned")
    check(all.count == 1, "recent day kept")

    // Clear removes everything.
    log.clear()
    check(ConversationLog.files(in: root).isEmpty, "clear removes files")

    // Unserialisable fields are skipped, not crashing.
    log.record("bad", ["value": Double.nan])
    check(lines().isEmpty, "invalid JSON skipped")

    print(failures == 0 ? "Conversation log tests passed (\(count))" : "Conversation log tests: \(failures) of \(count) failed")
    exit(failures == 0 ? 0 : 1)
 }
}
