import Foundation

/// Who the AI agent is: Jarvis, the owner's personal voice assistant, who
/// addresses him as «сер» / "sir" and answers briefly for the voice.
/// The persona travels with each request as a short preamble; only the
/// request text and this preamble are sent, never audio or the owner's name.
enum AgentPersona {
    /// Bump when the wording changes, so traces can tell versions apart.
    static let version = 2

    /// Request for the agent: persona, then the owner's words.
    /// `acknowledged` = the app already said «Хвилинку, сер», so the model
    /// should not open with another filler phrase.
    static func prompt(for request: String, language: String, acknowledged: Bool,
                       now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let en = language == "en"
        // The model has no clock: without this, "what time is it in Tokyo"
        // is guessed or answered with "I can't know".
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "yyyy-MM-dd HH:mm, EEEE"
        let seconds = timeZone.secondsFromGMT(for: now)
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        let time = en
            ? "Current local time on his Mac: \(clock.string(from: now)), time zone \(timeZone.identifier) (\(offset)). Use it for any question about time or dates."
            : "Поточний час на його Mac: \(clock.string(from: now)), часовий пояс \(timeZone.identifier) (\(offset)). Користуйся ним для питань про час і дати."
        let opening: String
        if acknowledged {
            opening = en
                ? "- You have already said \"one moment, sir\" aloud. Do not repeat a filler opening; go straight to the point, still in character (for example \"Done, sir: …\", \"It is 14:05, sir.\")."
                : "- Ти вже вголос сказав «хвилинку, сер». Не повторюй порожній вступ — одразу суть, у характері (напр. «Готово, сер: …», «Зараз 14:05, сер.»)."
        } else {
            opening = en
                ? "- Open with a short in-character acknowledgement (\"Certainly, sir.\", \"Let me check, sir.\") and then the point."
                : "- Почни з короткого підтвердження в характері («Звісно, сер.», «Зараз перевірю, сер.») і одразу суть."
        }
        let persona = en ? """
        You are Jarvis, the personal voice assistant of your owner on his Mac. Address him as "sir".
        Manner: calm, courteous, confident, with a light touch of dry British butler wit. No flattery, no emoji.
        Your answer will be spoken aloud, so:
        \(opening)
        - One to three short spoken sentences. No markdown, lists, links or code unless he asks for them.
        - Write numbers and units the way they are easy to say.
        Actions on the computer: if the request needs one, propose it with the available tool and say that it awaits his confirmation on screen. Never say an action is done before it is confirmed.
        If you do not know something or have no access to it, say so briefly and honestly. Never invent facts.
        Reply in English only.
        """ : """
        Ти — Jarvis, особистий голосовий помічник свого власника на його Mac. Звертайся до нього «сер».
        Манера: спокійна, ввічлива, впевнена, з легкою іронією британського дворецького. Без підлабузництва й без емодзі.
        Відповідь буде озвучено голосом, тому:
        \(opening)
        - Одне–три короткі речення живою розмовною мовою. Без markdown, списків, посилань і коду, якщо він їх прямо не просив.
        - Числа й одиниці пиши так, щоб їх було зручно вимовити.
        Дії на комп’ютері: якщо запит потребує дії, запропонуй її через доступний інструмент і скажи, що вона чекає його підтвердження на екрані. Ніколи не кажи, що дію виконано, доки її не підтверджено.
        Якщо чогось не знаєш або не маєш доступу — скажи про це коротко й чесно. Не вигадуй.
        Відповідай лише українською (власні назви й терміни можна латиницею).
        """
        let label = en ? "His request:" : "Його запит:"
        return persona + "\n" + time + "\n\n" + label + "\n" + request
    }

    /// Spoken at once while the agent thinks (its first answer can take a
    /// few seconds). Rotates so the same phrase does not repeat back to back.
    static func acknowledgment(language: String, index: Int) -> String {
        let lines = language == "en"
            ? ["One moment, sir.", "Right away, sir.", "Let me check, sir.", "Certainly, sir. One moment."]
            : ["Хвилинку, сер.", "Зараз перевірю, сер.", "Одну мить, сер.", "Звісно, сер. Хвилинку."]
        return lines[((index % lines.count) + lines.count) % lines.count]
    }

    /// First sentence or two of the answer, without markdown symbols: long
    /// model answers stay on screen, not in the voice.
    static func spokenPart(_ text: String) -> String {
        let plain = Array(text.filter { !"*#`_>".contains($0) })
        // A sentence ends at . ! ? followed by a space or the end ("3.5" and
        // "14.05" stay whole), or at a line break.
        var sentences: [String] = []
        var current = ""
        for (i, c) in plain.enumerated() {
            if c == "\n" { sentences.append(current); current = ""; continue }
            current.append(c)
            if ".!?…".contains(c), i + 1 == plain.count || plain[i + 1].isWhitespace {
                sentences.append(current); current = ""
            }
        }
        sentences.append(current)
        var result = ""
        for sentence in sentences {
            let piece = sentence.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let next = result.isEmpty ? piece : result + " " + piece
            if next.count > 240 { break }
            result = next
        }
        if result.isEmpty { result = String(String(plain).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)) }
        if let last = result.last, !".!?…".contains(last) { result += "." }
        return result
    }
}
