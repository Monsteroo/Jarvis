import Foundation

struct ActionRegistry {
    func validate(_ action: Action) throws {
        func text(_ value: String, max: Int) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= max, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" })
            else { throw ActionError.invalidParameters }
        }
        func appName(_ value: String) throws {
            try text(value, max: 128)
            guard !value.contains("/"), !value.contains("\n") else { throw ActionError.invalidParameters }
        }
        func snapshotID(_ value: String) throws {
            guard (4...32).contains(value.count),
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw ActionError.invalidParameters
            }
        }
        func elementRef(_ value: String) throws {
            guard value.hasPrefix("e"), value.count >= 2, value.count <= 5,
                  let index = Int(value.dropFirst()), index >= 1 else {
                throw ActionError.invalidParameters
            }
        }
        switch action {
        case .openApp(let name), .quitApp(let name), .activateApp(let name):
            try appName(name)
        case .tabCloseActive(let name?), .tabCloseLast(let name?), .uiSnapshot(let name?):
            try appName(name)
        case .uiPress(let app, let snap, let ref):
            try appName(app)
            try snapshotID(snap)
            try elementRef(ref)
        case .uiSetValue(let app, let snap, let ref, let content):
            try appName(app)
            try snapshotID(snap)
            try elementRef(ref)
            try text(content, max: 4000)
        case .openURL(let raw): _ = try WebActions.validatedURL(raw)
        case .webSearch(let query): try text(query, max: 2048)
        case .dictate(let content): try text(content, max: 16_000)
        case .volumeSet(let percent): guard (0...100).contains(percent) else { throw ActionError.invalidParameters }
        case .volumeStep(let step): guard (-100...100).contains(step), step != 0 else { throw ActionError.invalidParameters }
        default: break
        }
    }

    /// Safe local actions run immediately; general UI element clicks and writes
    /// require owner confirmation unless explicitly allowlisted (e.g. Calculator).
    func policy(for action: Action) -> ApprovalPolicy {
        switch action {
        case .openApp, .activateApp, .quitApp, .openURL, .webSearch,
             .windowMinimize, .windowMaximize, .windowLeftHalf, .windowRightHalf, .windowMinimizeAll,
             .tabCloseActive, .tabCloseLast, .uiSnapshot,
             .volumeSet, .volumeStep, .mute, .dictate:
            return .immediate
        case .uiPress(let app, _, _):
            return UIElementSecurity.isSafeImmediatePressApp(name: app) ? .immediate : .confirmation
        case .uiSetValue:
            return .confirmation
        }
    }
}
