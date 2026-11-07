import Foundation

/// One line of docs/benchmarks/prompts.txt: `lang|text`.
struct Prompt: Equatable {
    let language: String
    let text: String
}

enum PromptSet {
    static func parse(_ contents: String) -> [Prompt] {
        contents.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let bar = trimmed.firstIndex(of: "|") else { return nil }
            let language = trimmed[..<bar].trimmingCharacters(in: .whitespaces)
            let text = trimmed[trimmed.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            guard !language.isEmpty, !text.isEmpty else { return nil }
            return Prompt(language: language, text: text)
        }
    }
}

/// A measured attempt. Audio is never part of the record; the transcript is.
struct MeasurementRecord: Codable, Equatable {
    enum Status: String, Codable { case ok, empty, error, skipped }
    var timestamp: String
    var model: String
    var languageSetting: String
    var pass: Int
    var promptIndex: Int
    var promptLanguage: String
    var expected: String
    var transcript: String
    var status: Status
    var timedOut: Bool
    var audioSeconds: Double
    var whisperSeconds: Double
    var responseSeconds: Double

    enum CodingKeys: String, CodingKey {
        case timestamp, model, pass, expected, transcript, status
        case languageSetting = "language_setting", promptIndex = "prompt_index"
        case promptLanguage = "prompt_language", timedOut = "timed_out"
        case audioSeconds = "audio_s", whisperSeconds = "whisper_s", responseSeconds = "response_s"
    }
}

/// Append-only JSONL log. Progress is derived from it, so the app can be closed between sessions.
final class MeasurementLog {
    let url: URL
    init(url: URL) { self.url = url }

    func records() -> [MeasurementRecord] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(MeasurementRecord.self, from: Data($0.utf8))
        }
    }

    func append(_ record: MeasurementRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// Which prompt comes next for a model + language setting: first pass with an unlogged prompt.
struct MeasurementProgress: Equatable {
    static let passes = 3
    let pass: Int
    let index: Int
    var finished: Bool { pass > Self.passes }

    static func next(records: [MeasurementRecord], model: String, languageSetting: String, promptCount: Int) -> MeasurementProgress {
        guard promptCount > 0 else { return MeasurementProgress(pass: passes + 1, index: 0) }
        var done = Set<Int>()
        for r in records where r.model == model && r.languageSetting == languageSetting {
            done.insert(r.pass * 10_000 + r.promptIndex)
        }
        for pass in 1...passes {
            for index in 0..<promptCount where !done.contains(pass * 10_000 + index) {
                return MeasurementProgress(pass: pass, index: index)
            }
        }
        return MeasurementProgress(pass: passes + 1, index: 0)
    }
}
