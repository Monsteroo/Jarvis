import Foundation

/// A closed action set: no shell, script, or arbitrary executable parameters.
enum Action: Equatable, Codable, Sendable {
    case openApp(String), quitApp(String), activateApp(String)
    case openURL(String), webSearch(String)
    case windowMinimize, windowMaximize, windowLeftHalf, windowRightHalf
    /// Every standard window of every other application (not Jarvis's own).
    case windowMinimizeAll
    case tabCloseActive(String?), tabCloseLast(String?)
    /// Fixed shortcuts that need no window reading: ⌘T in a browser, ⌘N in Notes,
    /// and the play/pause media key (a YouTube video or music).
    case tabNew(String?), noteNew, mediaPlayPause
    /// Switch to browser tab 1…8 (⌘1…⌘8); 9 is the last tab (⌘9). Reopen the last closed tab (⌘⇧T).
    case tabSelect(Int), tabReopen
    /// The tab to the left or right of the current one (⌃⇧Tab / ⌃Tab).
    case tabPrevious, tabNext
    case uiSnapshot(String?)
    case uiPress(app: String, snapshotID: String, ref: String)
    case uiSetValue(app: String, snapshotID: String, ref: String, text: String)
    case runShortcut(String)
    case clipboardRead, clipboardWrite(String), clipboardUndo, clipboardPaste(String)
    case volumeSet(Int), volumeStep(Int), mute(Bool), dictate(String)
}

struct ApprovalRequest: Equatable, Sendable {
    let id: UUID
    let turnID: UUID
    let action: Action
    let summary: String
    let expiresAt: Date
}

enum CommandOutcome: Equatable, Sendable {
    case done(summary: String)
    case partial(summary: String, details: String)
    case failed(reason: String)
    case needsApproval(ApprovalRequest)
    case notUnderstood
}

protocol CommandHandling: AnyObject {
    func handle(_ text: String, language: String) async -> CommandOutcome
}

enum ActionError: Error { case invalidParameters, unsupportedLanguage }

enum ApprovalPolicy { case immediate, confirmation }

struct ActionEvent: Equatable {
    enum Phase: Equatable { case started, finished(CommandOutcome) }
    let turnID: UUID
    let action: Action
    let phase: Phase
}

func actionText(_ language: String, _ uk: String, _ en: String) -> String {
    language == "en" ? en : uk
}
