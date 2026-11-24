import Foundation

/// The OpenAI and ElevenLabs keys: an environment variable first, then the
/// Keychain. Both are read once, off the main thread, at launch: a Keychain
/// access prompt would otherwise freeze the whole app while it waits for the
/// owner (seen 24.11.2026 after install). A missing key is cached as "", so it
/// is not looked up again on every request. Used from the main thread only.
final class APIKeyStore {
    enum Service: CaseIterable {
        case openAI, elevenLabs
        var keychainService: String { self == .openAI ? KeychainSecret.openAI : KeychainSecret.elevenLabs }
        var environmentName: String { self == .openAI ? "OPENAI_API_KEY" : "ELEVENLABS_API_KEY" }
    }

    /// False until the launch-time read finishes. Until then `key` never
    /// touches the Keychain on the main thread.
    private(set) var loaded = false
    private var cached: [Service: String] = [:]
    private let environment: [String: String]
    private let keychain: Keychain

    /// Keychain access, replaceable in tests.
    struct Keychain {
        var read: (String) -> String?
        var save: (String, String) -> Bool
        var delete: (String) -> Void
        static let system = Keychain(read: { KeychainSecret.read($0) },
                                     save: { KeychainSecret.save($0, $1) },
                                     delete: { KeychainSecret.delete($0) })
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment, keychain: Keychain = .system) {
        self.environment = environment
        self.keychain = keychain
    }

    /// Reads both keys in the background; `completion` runs on the main thread.
    /// A key saved from settings while the read was waiting wins.
    func load(completion: @escaping () -> Void) {
        let environment = self.environment
        let keychain = self.keychain
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [Service: String] = [:]
            for service in Service.allCases {
                found[service] = environment[service.environmentName] ?? keychain.read(service.keychainService) ?? ""
            }
            let result = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (service, value) in result where self.cached[service] == nil { self.cached[service] = value }
                self.loaded = true
                completion()
            }
        }
    }

    /// The key, or nil when there is none or the launch read is not done yet.
    func key(_ service: Service) -> String? {
        if cached[service] == nil, loaded {
            cached[service] = environment[service.environmentName] ?? keychain.read(service.keychainService)
        }
        return cached[service].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether a key is known, without reading the Keychain.
    func hasCachedKey(_ service: Service) -> Bool { !(cached[service] ?? "").isEmpty }

    func inEnvironment(_ service: Service) -> Bool { environment[service.environmentName] != nil }

    /// Saves to the Keychain and uses the key at once. False if the Keychain refused.
    func save(_ key: String, for service: Service) -> Bool {
        guard keychain.save(key, service.keychainService) else { return false }
        cached[service] = key
        return true
    }

    func delete(_ service: Service) {
        keychain.delete(service.keychainService)
        cached[service] = nil
    }
}
