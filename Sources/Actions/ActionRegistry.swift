import Foundation

struct ActionRegistry {
    func validate(_ action: Action) throws {
        func text(_ value: String, max: Int) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= max, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" })
            else { throw ActionError.invalidParameters }
        }
        switch action {
        case .openApp(let name), .quitApp(let name), .activateApp(let name):
            try text(name, max: 128)
            guard !name.contains("/"), !name.contains("\n") else { throw ActionError.invalidParameters }
        case .openURL(let raw): _ = try WebActions.validatedURL(raw)
        case .webSearch(let query): try text(query, max: 2048)
        case .dictate(let content): try text(content, max: 16_000)
        case .volumeSet(let percent): guard (0...100).contains(percent) else { throw ActionError.invalidParameters }
        case .volumeStep(let step): guard (-100...100).contains(step), step != 0 else { throw ActionError.invalidParameters }
        default: break
        }
    }

    /// Only non-destructive local actions are registered in this release slice.
    /// Future send/delete/purchase actions must explicitly add confirmation policy.
    func policy(for action: Action) -> ApprovalPolicy {
        switch action {
        case .openApp, .activateApp, .quitApp, .openURL, .webSearch,
             .windowMinimize, .windowMaximize, .windowLeftHalf, .windowRightHalf, .windowMinimizeAll,
             .volumeSet, .volumeStep, .mute, .dictate: return .immediate
        }
    }
}
