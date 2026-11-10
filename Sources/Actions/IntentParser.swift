import Foundation

/// Deliberately bounded grammar; ambiguous/multi-action requests go to the planner.
struct IntentParser {
    func parse(_ text: String, language: String) -> Action? {
        guard language == "uk" || language == "en" else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        // Preserve dictated content and search/URL payload verbatim.
        let payloadRules: [(String, (String) -> Action)] = language == "uk" ? [
            ("диктуй ", Action.dictate), ("знайди в інтернеті ", Action.webSearch),
            ("відкрий сайт ", Action.openURL)
        ] : [
            ("dictate ", Action.dictate), ("search the web for ", Action.webSearch),
            ("open website ", Action.openURL)
        ]
        for (prefix, build) in payloadRules where lower.hasPrefix(prefix) {
            let value = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : build(value)
        }
        let command = lower.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let phrases: [String: Action] = language == "uk" ? [
            "згорни вікно": .windowMinimize, "розгорни вікно": .windowMaximize,
            "перемісти вікно ліворуч": .windowLeftHalf, "перемісти вікно праворуч": .windowRightHalf,
            "зроби гучніше": .volumeStep(10), "зроби тихіше": .volumeStep(-10),
            "вимкни звук": .mute(true), "увімкни звук": .mute(false)
        ] : [
            "minimize window": .windowMinimize, "maximize window": .windowMaximize,
            "move window left": .windowLeftHalf, "move window right": .windowRightHalf,
            "volume up": .volumeStep(10), "volume down": .volumeStep(-10),
            "mute": .mute(true), "unmute": .mute(false)
        ]
        if let match = phrases[command] { return match }
        let volumePrefix = language == "uk" ? "гучність " : "set volume to "
        if command.hasPrefix(volumePrefix) {
            let digits = command.dropFirst(volumePrefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            if let percent = Int(digits) { return .volumeSet(percent) }
        }
        let appRules: [(String, (String) -> Action)] = language == "uk" ? [
            ("відкрий ", Action.openApp), ("закрий ", Action.quitApp),
            ("активуй ", Action.activateApp), ("перемкнись на ", Action.activateApp),
            ("перемкнися на ", Action.activateApp)
        ] : [("open ", Action.openApp), ("quit ", Action.quitApp), ("close ", Action.quitApp), ("activate ", Action.activateApp)]
        for (prefix, build) in appRules where command.hasPrefix(prefix) {
            let name = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            let markers = [" і ", " та ", " and ", ";", "\n"]
            guard !name.isEmpty, !markers.contains(where: { name.contains($0) }) else { return nil }
            return build(name)
        }
        return nil
    }
}
