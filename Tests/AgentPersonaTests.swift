import Foundation

@main struct AgentPersonaTests {
 static func main() {
    var failures = 0, count = 0
    func check(_ ok: Bool, _ what: String) {
        count += 1
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    // Persona: role, form of address, voice-friendly, honest about actions.
    let uk = AgentPersona.prompt(for: "Яка погода в Києві?", language: "uk", acknowledged: true)
    check(uk.contains("Jarvis"), "uk names Jarvis")
    check(uk.contains("«сер»"), "uk addresses «сер»")
    check(uk.contains("підтвердження"), "uk waits for confirmation")
    check(uk.contains("Не вигадуй"), "uk forbids invention")
    check(uk.contains("лише українською"), "uk fixes language")
    check(uk.hasSuffix("Його запит:\nЯка погода в Києві?"), "uk request last, verbatim")
    check(uk.contains("хвилинку, сер"), "uk knows acknowledgment was spoken")
    let ukFresh = AgentPersona.prompt(for: "x", language: "uk", acknowledged: false)
    check(ukFresh.contains("Звісно, сер."), "uk opens in character when nothing was said")
    check(!ukFresh.contains("Ти вже вголос"), "uk does not claim a spoken acknowledgment")

    let en = AgentPersona.prompt(for: "What time is it?", language: "en", acknowledged: false)
    check(en.contains("\"sir\""), "en addresses sir")
    check(en.contains("English only"), "en fixes language")
    check(en.hasSuffix("His request:\nWhat time is it?"), "en request last")
    check(!en.contains("сер"), "en has no Ukrainian")
    check(!uk.lowercased().contains("russian") && !uk.lowercased().contains("росій"), "no third language")
    check(uk.count < 1500 && en.count < 1500, "preamble stays short (budget: 15,900 chars per request)")

    // The model gets the local clock (it has none of its own).
    let kyiv = TimeZone(identifier: "Europe/Kyiv")!
    let moment = ISO8601DateFormatter().date(from: "2026-11-10T15:05:00Z")!
    let timed = AgentPersona.prompt(for: "Котра година в Токіо?", language: "uk", acknowledged: true, now: moment, timeZone: kyiv)
    check(timed.contains("2026-11-10 17:05, Tuesday"), "uk local time")
    check(timed.contains("Europe/Kyiv (UTC+02:00)"), "uk zone and offset")
    let ny = AgentPersona.prompt(for: "x", language: "en", acknowledged: true, now: moment, timeZone: TimeZone(identifier: "America/New_York")!)
    check(ny.contains("10:05") && ny.contains("UTC-05:00"), "negative offset")
    check(timed.hasSuffix("Його запит:\nКотра година в Токіо?"), "request still last")

    // Acknowledgment rotates and never repeats back to back.
    for language in ["uk", "en"] {
        let lines = (0..<8).map { AgentPersona.acknowledgment(language: language, index: $0) }
        check(zip(lines, lines.dropFirst()).allSatisfy { $0 != $1 }, "\(language) acknowledgment rotates")
        check(lines.allSatisfy { $0.lowercased().contains(language == "en" ? "sir" : "сер") }, "\(language) acknowledgment addresses")
        check(lines.allSatisfy { $0.count <= 40 }, "\(language) acknowledgment short")
    }
    check(AgentPersona.acknowledgment(language: "uk", index: -1) == AgentPersona.acknowledgment(language: "uk", index: 3), "negative index safe")

    // Spoken part.
    func spoken(_ input: String, _ expected: String) {
        let got = AgentPersona.spokenPart(input)
        check(got == expected, "spoken «\(input)» → «\(got)», expected «\(expected)»")
    }
    spoken("Звісно, сер. Зараз 14:05.", "Звісно, сер. Зараз 14:05.")
    spoken("Курс 41.5 гривні, сер.", "Курс 41.5 гривні, сер.")
    spoken("**Готово**, сер!", "Готово, сер!")
    spoken("Так, сер? Уточніть місто.", "Так, сер? Уточніть місто.")
    spoken("Ось план:\n- перший крок\n- другий", "Ось план: - перший крок - другий.")
    spoken("Без крапки", "Без крапки.")
    spoken(String(repeating: "а", count: 300), String(repeating: "а", count: 240) + ".")
    let long = "Перше речення, сер. " + String(repeating: "дуже довге ", count: 30) + "друге."
    spoken(long, "Перше речення, сер.")

    print(failures == 0 ? "Agent persona tests passed (\(count))" : "Agent persona tests: \(failures) of \(count) failed")
    exit(failures == 0 ? 0 : 1)
 }
}
