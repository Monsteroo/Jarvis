import Foundation

struct GooseMCPServer: Sendable {
    private let helper: URL
    private let endpoint: AgentIPCEndpoint
    init(helper: URL, endpoint: AgentIPCEndpoint) throws {
        guard helper.isFileURL, helper.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helper.path),
              endpoint.capability.count == 64 else { throw AgentError.invalidConfiguration }
        self.helper = helper; self.endpoint = endpoint
    }
    var descriptor: JSONValue {
        .object(["name": .string("jarvis"), "command": .string(helper.path), "args": .array([.string("--jarvis-mcp-bridge")]),
            "env": .array([
                .object(["name": .string("JARVIS_MCP_SOCKET"), "value": .string(endpoint.socketPath)]),
                .object(["name": .string("JARVIS_MCP_CAPABILITY"), "value": .string(endpoint.capability)])])])
    }
}

enum AgentMCPHelper {
    /// The helper has no executor, keychain access, file tools, or native approval capability.
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let path = environment["JARVIS_MCP_SOCKET"], let capability = environment["JARVIS_MCP_CAPABILITY"] else { throw AgentError.invalidConfiguration }
        let connection = try AgentIPCConnection(endpoint: AgentIPCEndpoint(socketPath: path, capability: capability))
        let reader = AgentFrameReader(STDIN_FILENO)
        while let request = try reader.next() {
            if let response = try connection.exchange(request) { try AgentSocket.send(response, fd: STDOUT_FILENO) }
        }
    }
}
