import Foundation

@main struct JarvisMCPHelperMain {
    static func main() {
        guard CommandLine.arguments.dropFirst() == ["--jarvis-mcp-bridge"] else { exit(2) }
        do { try AgentMCPHelper.run() } catch { exit(1) }
    }
}
