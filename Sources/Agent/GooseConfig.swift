import Foundation
import CryptoKit

struct GooseConfig {
    static let version = "1.58.1"
    // Verified archive in research: e6667ba0741efc959f09a7ccadbad368f0ca3c47de77395d4d5d120a81301d4f.
    static let executableSHA256 = "6e1ffe11b7e54db34adf56a1ef1f3bf3c3493c8ac259ad45c49eb8299e73e0b7"
    let provider: String
    let model: String
    let root: URL
    var configurationFile: URL { root.appendingPathComponent("config/config.yaml") }
    init(provider: String, model: String, root: URL) throws {
        guard ["openai", "anthropic", "openrouter"].contains(provider), !model.isEmpty, model.count <= 128,
              model.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil,
              root.isFileURL, root.path.hasPrefix("/") else { throw AgentError.invalidConfiguration }
        self.provider = provider; self.model = model; self.root = root
    }
    /// User-selected provider for Jarvis. The model remains configurable.
    static func openAI(root: URL, model: String = "gpt-5.4-mini") throws -> GooseConfig {
        try GooseConfig(provider: "openai", model: model, root: root)
    }
    func verifyExecutable(_ executable: URL) throws {
        guard executable.isFileURL,
              let data = try? Data(contentsOf: executable, options: .mappedIfSafe), data.count <= 100_000_000,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.executableSHA256 else { throw AgentError.invalidConfiguration }
    }
    func writeLockedConfiguration() throws {
        try PrivateAgentFiles.directory(root)
        for name in ["config", "data", "state", "work", "tmp", ".agents/plugins", ".agents/agents"] {
            try PrivateAgentFiles.directory(root.appendingPathComponent(name))
        }
        var yaml = "GOOSE_PROVIDER: \(provider)\nGOOSE_MODEL: \(model)\nGOOSE_MODE: approve\nGOOSE_TELEMETRY_ENABLED: false\nGOOSE_DISABLE_SESSION_NAMING: true\nGOOSE_MAX_TURNS: 8\nextensions:\n"
        for name in ["code_execution", "chatrecall", "analyze", "tom", "developer", "skills", "summon", "scheduler", "summarize", "todo", "apps", "extensionmanager"] {
            yaml += "  \(name):\n    enabled: false\n    type: platform\n    name: \(name)\n    bundled: true\n"
        }
        try PrivateAgentFiles.lock(configurationFile) { try PrivateAgentFiles.write(Data(yaml.utf8), to: configurationFile) }
    }
    /// A fresh explicit environment: never copy parent secrets or arbitrary GOOSE_* settings.
    func environment(apiKey: String) -> [String: String] {
        let keyName = ["openai": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "openrouter": "OPENROUTER_API_KEY"][provider]!
        return ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": root.appendingPathComponent("tmp").path,
                "GOOSE_PATH_ROOT": root.path, "GOOSE_MODE": "approve", "GOOSE_MAX_TURNS": "8",
                "GOOSE_DISABLE_SESSION_NAMING": "true", "GOOSE_TELEMETRY_OFF": "1",
                "GOOSE_DISABLE_KEYRING": "1", keyName: apiKey]
    }
}
