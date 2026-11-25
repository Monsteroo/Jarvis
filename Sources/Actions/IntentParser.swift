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
        let shortcutPrefixes = language == "uk"
            ? ["запусти команду ", "запусти шорткат ", "виконай команду "]
            : ["run shortcut "]
        for prefix in shortcutPrefixes where lower.hasPrefix(prefix) {
            let value = String(raw.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?«»\"'")))
            return value.isEmpty ? nil : .runShortcut(value)
        }
        let command = lower.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let phrases: [String: Action] = language == "uk" ? [
            "згорни вікно": .windowMinimize, "розгорни вікно": .windowMaximize,
            "згорни всі вікна": .windowMinimizeAll, "згорни вікна": .windowMinimizeAll, "згорни все": .windowMinimizeAll,
            "перемісти вікно ліворуч": .windowLeftHalf, "перемісти вікно праворуч": .windowRightHalf,
            "закрий вкладку": .tabCloseActive(nil), "закрий поточну вкладку": .tabCloseActive(nil),
            "закрий активну вкладку": .tabCloseActive(nil), "закрий цю вкладку": .tabCloseActive(nil),
            "закрий останню вкладку": .tabCloseLast(nil),
            "нова вкладка": .tabNew(nil), "відкрий нову вкладку": .tabNew(nil), "відкрий вкладку": .tabNew(nil),
            "перейди на останню вкладку": .tabSelect(9), "відкрий останню вкладку": .tabSelect(9),
            "перейди на першу вкладку": .tabSelect(1), "відкрий першу вкладку": .tabSelect(1),
            "попередня вкладка": .tabPrevious, "перемкнись на попередню вкладку": .tabPrevious, "перейди на попередню вкладку": .tabPrevious,
            "наступна вкладка": .tabNext, "перемкнись на наступну вкладку": .tabNext, "перейди на наступну вкладку": .tabNext,
            "поверни закриту вкладку": .tabReopen, "відкрий закриту вкладку": .tabReopen, "поверни вкладку": .tabReopen,
            "нова нотатка": .noteNew, "створи нову нотатку": .noteNew, "створи нотатку": .noteNew,
            "пауза": .mediaPlayPause, "постав на паузу": .mediaPlayPause, "постав відео на паузу": .mediaPlayPause,
            "зупини відео": .mediaPlayPause, "продовж відео": .mediaPlayPause, "продовжи відео": .mediaPlayPause,
            "зроби гучніше": .volumeStep(10), "зроби тихіше": .volumeStep(-10),
            "вимкни звук": .mute(true), "увімкни звук": .mute(false),
            "поверни попередній буфер": .clipboardUndo, "поверни буфер": .clipboardUndo,
            "віднови буфер": .clipboardUndo, "віднови попередній буфер": .clipboardUndo
        ] : [
            "minimize window": .windowMinimize, "maximize window": .windowMaximize,
            "minimize all windows": .windowMinimizeAll, "minimize everything": .windowMinimizeAll,
            "move window left": .windowLeftHalf, "move window right": .windowRightHalf,
            "close tab": .tabCloseActive(nil), "close active tab": .tabCloseActive(nil),
            "close current tab": .tabCloseActive(nil), "close this tab": .tabCloseActive(nil),
            "close last tab": .tabCloseLast(nil),
            "new tab": .tabNew(nil), "open new tab": .tabNew(nil), "open a new tab": .tabNew(nil),
            "go to the last tab": .tabSelect(9), "switch to the last tab": .tabSelect(9), "go to the first tab": .tabSelect(1),
            "previous tab": .tabPrevious, "go to the previous tab": .tabPrevious, "switch to the previous tab": .tabPrevious,
            "next tab": .tabNext, "go to the next tab": .tabNext, "switch to the next tab": .tabNext,
            "reopen closed tab": .tabReopen, "reopen the closed tab": .tabReopen, "reopen tab": .tabReopen,
            "new note": .noteNew, "create a new note": .noteNew, "create a note": .noteNew,
            "pause": .mediaPlayPause, "pause the video": .mediaPlayPause, "pause video": .mediaPlayPause,
            "resume video": .mediaPlayPause, "resume the video": .mediaPlayPause,
            "volume up": .volumeStep(10), "volume down": .volumeStep(-10),
            "mute": .mute(true), "unmute": .mute(false),
            "restore previous clipboard": .clipboardUndo, "restore clipboard": .clipboardUndo,
            "undo clipboard": .clipboardUndo
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
