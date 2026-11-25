import Foundation

/// Shortcut actions with a fake: no real key is posted.
@main struct ShortcutActionTests {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: \(message)") }
            count += 1
        }

        let parser = IntentParser()
        let registry0 = ActionRegistry()
        check(parser.parse("Відкрий нову вкладку.", language: "uk") == .tabNew(nil), "uk new tab")
        check(parser.parse("нова нотатка", language: "uk") == .noteNew, "uk new note")
        check(parser.parse("Створи нову нотатку!", language: "uk") == .noteNew, "uk create note")
        check(parser.parse("Постав на паузу.", language: "uk") == .mediaPlayPause, "uk pause")
        check(parser.parse("зупини відео", language: "uk") == .mediaPlayPause, "uk stop video")
        check(parser.parse("Open a new tab", language: "en") == .tabNew(nil), "en new tab")
        check(parser.parse("pause the video", language: "en") == .mediaPlayPause, "en pause")
        check(parser.parse("Відкрий останню вкладку.", language: "uk") == .tabSelect(9), "uk open last tab = switch")
        check(parser.parse("закрий останню вкладку", language: "uk") == .tabCloseLast(nil), "uk close last tab unchanged")
        check(parser.parse("Поверни закриту вкладку", language: "uk") == .tabReopen, "uk reopen tab")
        check(parser.parse("go to the first tab", language: "en") == .tabSelect(1), "en first tab")
        check(parser.parse("Перемкнись на попередню вкладку.", language: "uk") == .tabPrevious, "uk previous tab")
        check(parser.parse("next tab", language: "en") == .tabNext, "en next tab")
        check((try? registry0.validate(.tabSelect(0))) == nil && (try? registry0.validate(.tabSelect(10))) == nil, "tab index 1…9")

        let registry = ActionRegistry()
        for action in [Action.tabNew(nil), .tabNew("Google Chrome"), .noteNew, .mediaPlayPause, .tabSelect(9), .tabReopen, .tabPrevious, .tabNext] {
            check((try? registry.validate(action)) != nil, "valid \(action)")
            check(registry.policy(for: action) == .immediate, "immediate \(action)")
        }
        check((try? registry.validate(.tabNew("bad/path"))) == nil, "tab target validated")

        let fake = FakeShortcutAccess()
        let actions = ShortcutActions(access: fake)
        check(await actions.perform(.tabNew(nil), language: "uk") == .done(summary: "Нову вкладку у «Google Chrome» відкрито."), "new tab done")
        check(fake.pressed == [.newTab] && fake.lastBrowser == true, "⌘T after bringing the browser forward")
        check(await actions.perform(.noteNew, language: "en") == .done(summary: "Created a new note."), "new note done")
        check(fake.pressed == [.newTab, .newNote] && fake.lastQuery == "com.apple.Notes", "⌘N goes to Notes")
        check(await actions.perform(.mediaPlayPause, language: "uk") == .done(summary: "Паузу або відтворення перемкнено."), "play/pause")
        check(fake.playPauses == 1, "media key once")
        check(await actions.perform(.tabSelect(9), language: "uk") == .done(summary: "Перейшов на останню вкладку у «Google Chrome»."), "last tab")
        check(await actions.perform(.tabReopen, language: "en") == .done(summary: "Reopened the closed tab in ‘Google Chrome’."), "reopen tab")
        check(fake.pressed.suffix(2) == [.selectTab(9), .reopenTab], "⌘9 and ⌘⇧T")
        check(await actions.perform(.tabPrevious, language: "uk") == .done(summary: "Перейшов на попередню вкладку."), "previous tab")
        check(await actions.perform(.tabNext, language: "en") == .done(summary: "Switched to the next tab."), "next tab")
        check(fake.pressed.suffix(2) == [.previousTab, .nextTab], "⌃⇧Tab and ⌃Tab")

        fake.frontmostFails = true
        if case .failed(let reason) = await actions.perform(.tabNew(nil), language: "uk") {
            check(reason.contains("нічого не натиснуто"), "no key when the app is not in front")
        } else { fatalError("must fail when not frontmost") }
        check(fake.pressed.count == 6, "nothing pressed on failure")

        fake.trusted = false
        if case .failed(let reason) = await actions.perform(.mediaPlayPause, language: "uk") {
            check(reason.contains("Доступність"), "untrusted")
        } else { fatalError("untrusted must fail") }

        print("Shortcut action tests: \(count) checks passed")
    }
}

@MainActor private final class FakeShortcutAccess: ShortcutAccess {
    var trusted = true
    var frontmostFails = false
    private(set) var pressed: [ShortcutKey] = []
    private(set) var playPauses = 0
    private(set) var lastQuery: String?
    private(set) var lastBrowser: Bool?

    func bringForward(appQuery: String?, browser: Bool) async throws -> (name: String, pid: pid_t) {
        lastQuery = appQuery; lastBrowser = browser
        return browser ? ("Google Chrome", 700) : ("Нотатки", 701)
    }
    func press(_ key: ShortcutKey, expectedPID: pid_t) throws {
        if frontmostFails { throw ShortcutError.notFrontmost }
        pressed.append(key)
    }
    func playPause() throws { playPauses += 1 }
}
