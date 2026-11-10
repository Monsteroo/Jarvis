import Foundation

@main struct CloudVoiceTests {
 static func main() throws {
    var failures = 0, count = 0
    func check(_ ok: Bool, _ name: String) { count += 1; if !ok { failures += 1; print("FAIL: \(name)") } }

    // Request
    let voice = "K74pMNmxBnAW8cPpeyph"
    let request = ElevenLabsRequest.make(text: "Слухаю. Відкриваю браузер.", voiceID: voice, language: "uk", apiKey: "test-key")
    check(request?.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_128", "endpoint and format")
    check(request?.httpMethod == "POST", "POST")
    check(request?.value(forHTTPHeaderField: "xi-api-key") == "test-key", "key only in header")
    check(request?.url?.absoluteString.contains("test-key") == false, "key never in URL")
    let body = (try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data())) as? [String: String]
    check(body?["text"] == "Слухаю. Відкриваю браузер.", "text sent as is")
    check(body?["model_id"] == "eleven_flash_v2_5", "flash model")
    check(body?["language_code"] == "uk", "language fixed to uk")
    check(ElevenLabsRequest.make(text: "Hi", voiceID: voice, language: "en", apiKey: "k").map { r in
        ((try? JSONSerialization.jsonObject(with: r.httpBody!)) as? [String: String])?["language_code"] == "en" } == true, "language fixed to en")
    check(ElevenLabsRequest.make(text: "Привіт", voiceID: voice, language: "ru", apiKey: "k") == nil, "only uk/en")
    check(ElevenLabsRequest.make(text: "Привіт", voiceID: voice, language: "", apiKey: "k") == nil, "no autodetect")
    check(ElevenLabsRequest.make(text: "  ", voiceID: voice, language: "uk", apiKey: "k") == nil, "empty text")
    check(ElevenLabsRequest.make(text: "Привіт", voiceID: voice, language: "uk", apiKey: "") == nil, "no key")
    check(ElevenLabsRequest.make(text: "Привіт", voiceID: "../voices", language: "uk", apiKey: "k") == nil, "voice ID cannot alter the path")
    check(!ElevenLabsRequest.isValidVoiceID("short"), "too short ID")
    check(ElevenLabsRequest.explain(status: 401).contains("ключ"), "401 explained")
    check(ElevenLabsRequest.explain(status: nil).contains("зв’язку"), "offline explained")

    // Errors switch to the macOS voice; account-level ones pause the cloud.
    let quota = #"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota."}}"#.data(using: .utf8)
    check(ElevenLabsRequest.errorCode(quota) == "quota_exceeded", "reads the machine-readable code")
    check(ElevenLabsRequest.explain(status: 401, code: "quota_exceeded").contains("кредити"), "quota is not reported as a bad key")
    check(ElevenLabsRequest.isLasting(status: 401, code: "quota_exceeded"), "quota pauses the cloud")
    check(ElevenLabsRequest.isLasting(status: 401, code: nil), "bad key pauses the cloud")
    check(!ElevenLabsRequest.isLasting(status: nil, code: nil), "network error retries next time")
    check(!ElevenLabsRequest.isLasting(status: 500, code: nil), "server error retries next time")
    check(!ElevenLabsRequest.isLasting(status: 404, code: "voice_not_found"), "wrong voice retries after the ID is fixed")
    check(ElevenLabsRequest.errorCode("not json".data(using: .utf8)) == nil && ElevenLabsRequest.errorCode(nil) == nil, "odd bodies are ignored")

    // Ledger
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    let nov = f.date(from: "2026-11-10")!, dec = f.date(from: "2026-12-01")!
    var ledger = VoiceUsageLedger()
    check(ledger.allows(100, limit: 100, at: nov), "exactly at the limit is allowed")
    ledger.record(60, at: nov)
    check(ledger.used(at: nov) == 60 && !ledger.allows(41, limit: 100, at: nov), "over the limit refused")
    ledger.record(-60, at: nov)
    check(ledger.used(at: nov) == 0, "failed request refunded")
    ledger.record(90, at: nov)
    check(ledger.used(at: dec) == 0 && ledger.allows(100, limit: 100, at: dec), "new month starts at zero")
    ledger.record(10, at: dec)
    check(ledger.month == "2026-12" && ledger.characters == 10, "month rolls over")
    let defaults = UserDefaults(suiteName: "jarvis-cloud-test-\(UUID().uuidString)")!
    ledger.save(defaults)
    check(VoiceUsageLedger.load(defaults) == ledger, "ledger persists")

    if failures > 0 { print("CloudVoiceTests: \(failures)/\(count) failed"); exit(1) }
    print("CloudVoiceTests: \(count) checks passed")
 }
}
