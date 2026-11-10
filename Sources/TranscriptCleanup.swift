import Foundation

/// Fixes known non-Ukrainian word forms that Parakeet sometimes emits in
/// Ukrainian mode («открій», «доллара»). Output is always Ukrainian; this is
/// an ASR correction table, not support for another language. Applied only
/// when the language setting is "uk". Measurement logs keep the raw ASR text.
enum TranscriptCleanup {
    /// Whole-word replacements (lower-case keys).
    static let words: [String: String] = [
        "открой": "відкрий", "открий": "відкрий", "открій": "відкрий", "откри": "відкрий",
        "откройте": "відкрийте", "откріть": "відкрити", "открити": "відкрити", "открить": "відкрити",
        "закрой": "закрий", "закройте": "закрийте",
        "включи": "увімкни", "включіть": "увімкніть", "включити": "увімкнути",
        "виключи": "вимкни", "виключіть": "вимкніть", "виключити": "вимкнути",
        "сделай": "зроби", "зделай": "зроби", "сдєлай": "зроби",
        "громче": "гучніше", "громкіше": "гучніше", "тише": "тихіше",
        "пожалуйста": "будь ласка", "сейчас": "зараз", "сєйчас": "зараз",
    ]

    /// Word-start replacements: no Ukrainian word starts with these.
    static let prefixes: [(String, String)] = [("доллар", "долар"), ("откр", "відкр")]

    static func normalize(_ text: String, language: String) -> String {
        guard language == "uk", !text.isEmpty else { return text }
        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty { result += fix(word); word = "" }
        }
        for character in text {
            if character.isLetter || character == "'" || character == "’" { word.append(character) } else { flush(); result.append(character) }
        }
        flush()
        return result
    }

    private static func fix(_ word: String) -> String {
        let lower = word.lowercased()
        var fixed: String?
        if let replacement = words[lower] {
            fixed = replacement
        } else if let (from, to) = prefixes.first(where: { lower.hasPrefix($0.0) }) {
            fixed = to + lower.dropFirst(from.count)
        }
        guard let fixed else { return word }
        if word.first?.isUppercase == true { return fixed.prefix(1).uppercased() + fixed.dropFirst() }
        return fixed
    }
}
