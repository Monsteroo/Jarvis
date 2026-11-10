import Foundation

@main struct TranscriptCleanupTests {
 static func main() {
    var failures = 0, count = 0
    func check(_ input: String, _ expected: String, language: String = "uk") {
        count += 1
        let got = TranscriptCleanup.normalize(input, language: language)
        if got != expected { failures += 1; print("FAIL: «\(input)» → «\(got)», expected «\(expected)»") }
    }
    // Seen from Parakeet on the user's voice.
    check("Открій браузер.", "Відкрий браузер.")
    check("Який курс доллара?", "Який курс долара?")
    // Inflections and case.
    check("откріть термінал", "відкрити термінал")
    check("ВІДКРИЙ", "ВІДКРИЙ")
    check("скільки долларів", "скільки доларів")
    check("відкриття, а не откриття", "відкриття, а не відкриття")
    check("Включи музику, будь ласка", "Увімкни музику, будь ласка")
    check("зроби громче", "зроби гучніше")
    check("Сделай тише, пожалуйста.", "Зроби тихіше, будь ласка.")
    // Correct Ukrainian is untouched.
    check("Відкрий термінал і закрий Safari.", "Відкрий термінал і закрий Safari.")
    check("Тиша в домі, долар росте.", "Тиша в домі, долар росте.")
    check("Включення світла", "Включення світла")
    check("Обов’язково зроби це", "Обов’язково зроби це")
    check("", "")
    // English is never changed.
    check("Open the browser", "Open the browser", language: "en")
    check("открій", "открій", language: "en")
    if failures > 0 { print("TranscriptCleanupTests: \(failures)/\(count) failed"); exit(1) }
    print("TranscriptCleanupTests: \(count) checks passed")
 }
}
