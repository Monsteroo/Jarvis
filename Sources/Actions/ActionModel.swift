import Foundation

/// A closed action set: no shell, script, or arbitrary executable parameters.
enum Action: Equatable, Codable, Sendable {
    case openApp(String), quitApp(String), activateApp(String)
    case openURL(String), webSearch(String)
    case windowMinimize, windowMaximize, windowLeftHalf, windowRightHalf
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
