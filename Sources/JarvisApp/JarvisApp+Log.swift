import AppKit

extension JarvisApp {
    // MARK: Conversation log (local text, for reviewing mistakes and latency)


    func logEvent(_ event: String, _ fields: [String: Any] = [:]) {
        conversationLog.enabled = store.conversationLog
        conversationLog.record(event, fields)
    }

    func revealConversations() {
        let directory = conversationLog.directory
        if let latest = ConversationLog.files(in: directory).last {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            store.conversationLogStatus = "Журнал поки порожній."
        }
    }

    func clearConversations() {
        conversationLog.clear()
        store.conversationLogStatus = "Журнал очищено."
    }

    static func rounded(_ value: Double?) -> Any {
        value.map { ($0 * 100).rounded() / 100 } ?? NSNull()
    }
}
