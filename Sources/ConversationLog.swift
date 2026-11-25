import Foundation

/// Local text log of conversations with Jarvis, for reviewing mistakes and
/// latency later. Text only — never audio. Files stay on this Mac in
/// ~/Library/Application Support/Jarvis/conversations (one JSON line per
/// event, one file per day, readable only by the owner) and are deleted
/// after `retentionDays`. The owner can switch it off or clear it in
/// Diagnostics. Never contains API keys.
final class ConversationLog: @unchecked Sendable {
    static let retentionDays = 30

    let directory: URL
    var enabled: Bool
    /// One id per app launch, so turn numbers from different launches differ.
    let session = String(UUID().uuidString.prefix(8)).lowercased()
    private var anchor: TimeInterval?
    private var turn = 0
    private let queue = DispatchQueue(label: "local.jarvis.conversation-log")
    private let clock: () -> TimeInterval
    private let now: () -> Date

    init(directory: URL, enabled: Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping () -> Date = Date.init) {
        self.directory = directory; self.enabled = enabled; self.clock = clock; self.now = now
    }

    /// A new turn starts when the owner stops speaking (`at` = that moment,
    /// system uptime). Later events report seconds since then in "t".
    func beginTurn(_ turn: Int, at uptime: TimeInterval) {
        self.turn = turn
        anchor = uptime
    }

    /// Seconds since the owner stopped speaking, if a turn is open.
    var elapsed: Double? { anchor.map { clock() - $0 } }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        // Mask only caller-supplied free text; the log's own ids are added after.
        var line = Self.mask(fields) as? [String: Any] ?? [:]
        line["event"] = event
        line["session"] = session
        line["turn"] = turn
        let date = now()
        line["time"] = Self.timestamp.string(from: date)
        if let elapsed { line["t"] = (elapsed * 100).rounded() / 100 }
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        let file = directory.appendingPathComponent(Self.day.string(from: date) + ".jsonl")
        let directory = self.directory
        queue.async { Self.append(data, to: file, directory: directory) }
    }

    static let redactionMarker = "[ключ приховано]"

    private static let secretPatterns: [NSRegularExpression] = [
        // Bearer tokens.
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}"#,
        // OpenAI-style keys (sk-, sk-proj-).
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"#,
        // ElevenLabs-style keys.
        #"(?<![A-Za-z0-9])sk_[A-Za-z0-9]{20,}"#,
        // Bare long hex strings.
        #"(?<![A-Za-z0-9_-])[0-9a-fA-F]{32,}(?![A-Za-z0-9_-])"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let longToken = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#)

    /// Replaces key-like substrings in a string with `redactionMarker`.
    static func maskSecrets(_ text: String) -> String {
        var result = text
        for regex in secretPatterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: redactionMarker))
        }
        // Generic long tokens: must mix letters and digits (plain words/numbers stay).
        if let longToken {
            let ns = result as NSString
            for match in longToken.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let token = ns.substring(with: match.range)
                if token.contains(where: \.isLetter) && token.contains(where: \.isNumber) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: redactionMarker)
                }
            }
        }
        return result
    }

    /// Recursively masks every string inside a JSON-like value.
    static func mask(_ value: Any) -> Any {
        switch value {
        case let s as String: return maskSecrets(s)
        case let d as [String: Any]: return d.mapValues { mask($0) }
        case let a as [Any]: return a.map { mask($0) }
        default: return value
        }
    }

    /// Waits for pending writes (tests, quitting).
    func flush() { queue.sync {} }

    func clear() {
        let directory = self.directory
        queue.sync {
            for file in Self.files(in: directory) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Deletes day files older than the retention period.
    func prune() {
        let directory = self.directory
        let cutoff = Self.day.string(from: now().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        queue.async {
            for file in Self.files(in: directory) where file.deletingPathExtension().lastPathComponent < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func files(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func append(_ data: Data, to file: URL, directory: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
