import Foundation
import Security

/// API keys live in the macOS Keychain. The user types the key into the app
/// (or sets an environment variable); it is never logged or shown again.
enum KeychainSecret {
    static let elevenLabs = "local.jarvis.voicelab.elevenlabs"
    static let openAI = "local.jarvis.voicelab.openai"

    static func read(_ service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ secret: String, _ service: String) -> Bool {
        delete(service)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "api-key", kSecValueData as String: Data(secret.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// ElevenLabs text-to-speech request. Only reply text leaves the Mac; the
/// language is fixed to uk or en (no autodetection).
enum ElevenLabsRequest {
    static let model = "eleven_flash_v2_5"
    /// List price used for the estimate shown in settings (USD per 1000 characters).
    static let pricePerThousand = 0.04

    static func isValidVoiceID(_ id: String) -> Bool {
        (10...40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func make(text: String, voiceID: String, language: String, apiKey: String) -> URLRequest? {
        guard language == "uk" || language == "en", isValidVoiceID(voiceID), !apiKey.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5) // then the macOS voice answers
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": model, "language_code": language])
        return request
    }

    /// ElevenLabs reports problems as {"detail": {"status": "quota_exceeded", …}}.
    /// Only that machine-readable code is used; the message text is ignored.
    static func errorCode(_ body: Data?) -> String? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = json["detail"] as? [String: Any] else { return nil }
        return detail["status"] as? String
    }

    /// Account-level failures that will repeat on every request for a while;
    /// the app then answers with the macOS voice without waiting on the network.
    static func isLasting(status: Int?, code: String?) -> Bool {
        if let code, ["quota_exceeded", "invalid_api_key", "missing_permissions", "payment_required"].contains(code) { return true }
        return status == 401 || status == 402
    }

    /// Short, recoverable explanation for a failed request (no response body is shown).
    static func explain(status: Int?, code: String? = nil) -> String {
        switch code {
        case "quota_exceeded": return "кредити ElevenLabs на цей місяць вичерпано"
        case "voice_not_found": return "голос ElevenLabs не знайдено — перевірте ID або додайте голос у свій акаунт"
        case "missing_permissions": return "ключу ElevenLabs бракує дозволу Text to Speech"
        default: break
        }
        switch status {
        case 401: return "ключ ElevenLabs не прийнято — перевірте його"
        case 402: return "на рахунку ElevenLabs закінчились кредити"
        case 404: return "голос ElevenLabs не знайдено — перевірте ID"
        case 429: return "ElevenLabs обмежив частоту запитів"
        case nil: return "немає зв’язку з ElevenLabs"
        default: return "ElevenLabs відповів кодом \(status!)"
        }
    }
}

/// Characters sent this calendar month. Counts characters only, never text.
struct VoiceUsageLedger: Codable, Equatable {
    var month = ""
    var characters = 0

    static func monthKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private mutating func roll(_ now: Date) {
        let key = Self.monthKey(now)
        if month != key { month = key; characters = 0 }
    }

    func used(at now: Date) -> Int { month == Self.monthKey(now) ? characters : 0 }

    func allows(_ count: Int, limit: Int, at now: Date) -> Bool { used(at: now) + count <= limit }

    mutating func record(_ count: Int, at now: Date) {
        roll(now)
        characters += count
    }

    static func load(_ defaults: UserDefaults = .standard) -> VoiceUsageLedger {
        defaults.data(forKey: "elevenLabsUsage").flatMap { try? JSONDecoder().decode(VoiceUsageLedger.self, from: $0) } ?? VoiceUsageLedger()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "elevenLabsUsage") }
    }
}
