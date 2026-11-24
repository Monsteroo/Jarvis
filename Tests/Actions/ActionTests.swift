import Foundation

@main struct ActionTests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }; count += 1
        }
        let parser = IntentParser()
        let fixtures: [(String, String, Action)] = [
            ("Відкрий термінал!", "uk", .openApp("термінал")),
            ("відкрий браузер", "uk", .openApp("браузер")),
            ("відкрий пошту", "uk", .openApp("пошту")),
            ("Закрий Safari.", "uk", .quitApp("safari")),
            ("активуй Safari", "uk", .activateApp("safari")),
            ("відкрий сайт github.com", "uk", .openURL("github.com")),
            ("знайди в інтернеті котів & собак", "uk", .webSearch("котів & собак")),
            ("згорни вікно", "uk", .windowMinimize),
            ("Згорни всі вікна.", "uk", .windowMinimizeAll),
            ("згорни все", "uk", .windowMinimizeAll),
            ("розгорни вікно", "uk", .windowMaximize),
            ("перемісти вікно ліворуч", "uk", .windowLeftHalf),
            ("перемісти вікно праворуч", "uk", .windowRightHalf),
            ("зроби гучніше", "uk", .volumeStep(10)),
            ("зроби тихіше", "uk", .volumeStep(-10)),
            ("вимкни звук", "uk", .mute(true)),
            ("увімкни звук", "uk", .mute(false)),
            ("гучність 30%", "uk", .volumeSet(30)),
            ("диктуй Привіт, світе!", "uk", .dictate("Привіт, світе!")),
            ("OPEN Terminal!", "en", .openApp("terminal")),
            ("open browser", "en", .openApp("browser")),
            ("open mail", "en", .openApp("mail")),
            ("quit Safari", "en", .quitApp("safari")),
            ("activate Safari", "en", .activateApp("safari")),
            ("open website https://example.com/a?x=1", "en", .openURL("https://example.com/a?x=1")),
            ("search the web for Swift & macOS", "en", .webSearch("Swift & macOS")),
            ("minimize window", "en", .windowMinimize),
            ("Minimize all windows.", "en", .windowMinimizeAll),
            ("maximize window", "en", .windowMaximize),
            ("move window left", "en", .windowLeftHalf),
            ("move window right", "en", .windowRightHalf),
            ("volume up", "en", .volumeStep(10)),
            ("volume down", "en", .volumeStep(-10)),
            ("mute", "en", .mute(true)),
            ("unmute", "en", .mute(false)),
            ("set volume to 50%", "en", .volumeSet(50)),
            ("dictate Hello, world!", "en", .dictate("Hello, world!"))
        ]
        for (text, language, expected) in fixtures {
            check(parser.parse(text, language: language) == expected, "Parse: \(text)")
        }
        for text in ["розкажи анекдот", "не відкривай Safari", "відкрий", "відкрий Safari і закрий Mail"] {
            check(parser.parse(text, language: "uk") == nil, "Reject unsupported: \(text)")
        }
        check(parser.parse("open terminal", language: "auto") == nil, "Reject unsupported language")
        check(parser.parse("open terminal", language: "uk") == nil, "Respect selected language")
        let registry = ActionRegistry()
        check(registry.policy(for: .openApp("terminal")) == .immediate, "Simple local action needs no cloud approval")
        check(registry.policy(for: .quitApp("safari")) == .immediate, "Normal quit never force quits")
        for bad in [Action.volumeSet(101), .volumeSet(-1), .volumeStep(0), .openApp(""), .webSearch(" "), .dictate("")] {
            check((try? registry.validate(bad)) == nil, "Invalid action rejected")
        }
        for raw in ["javascript:alert(1)", "file:///tmp/a", "https://user:pass@example.com", "https://", "https://exa mple.com", "https://example.com\n"] {
            check((try? WebActions.validatedURL(raw)) == nil, "Reject URL: \(raw)")
        }
        check(try WebActions.validatedURL("github.com").absoluteString == "https://github.com", "Add HTTPS")
        let query = "Swift & macOS + Київ?"
        check(URLComponents(url: try WebActions.searchURL(query), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query, "Search query preserved")
        let workspace = FakeWorkspace()
        let executor = ActionExecutor(workspace: workspace)
        let stream = await executor.events.subscribe()
        var iterator = stream.makeAsyncIterator()
        let outcome = await executor.handle("відкрий термінал", language: "uk")
        check(outcome == .done(summary: "Програму «термінал» відкрито."), "Verified application result")
        let first = await iterator.next(), second = await iterator.next()
        check(first?.phase == .started && second?.phase == .finished(outcome), "Ordered progress")
        check(first?.turnID == second?.turnID, "Same turn for progress")
        check(workspace.openCount == 1, "One application launch")
        workspace.setSuccess(false)
        if case .failed = await executor.handle("open terminal", language: "en") { count += 1 }
        else { fatalError("No success when adapter rejects") }
        check(await executor.handle("tell a joke", language: "en") == .notUnderstood, "Planner fallback")
        if case .failed = await executor.handle("open website javascript:alert(1)", language: "en") { count += 1 }
        else { fatalError("Dangerous URL rejected") }
        check(workspace.webCount == 0, "Rejected URL never reaches workspace")
        workspace.setSuccess(true)
        check(await executor.handle("search the web for Swift & macOS", language: "en") == .done(summary: "The link was handed to the browser."), "Honest browser acceptance")
        check(workspace.webCount == 1, "One browser dispatch")
        if case .failed = await executor.handle("open missing", language: "en") { count += 1 }
        else { fatalError("Missing application must fail") }
        let cancelledTask = Task { () -> CommandOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.handle("open terminal", language: "en")
        }
        if case .failed = await cancelledTask.value { count += 1 }
        else { fatalError("Cancelled task must fail") }
        check(workspace.openCount == 2, "Precancelled action has no side effect")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try AppAliases.defaults.save(to: temp)
        check(try AppAliases.load(from: temp).bundleIDs["термінал"] == "com.apple.Terminal", "JSON aliases round trip")
        print("Action tests: \(count) checks passed")
    }
}

@MainActor final class FakeWorkspace: ActionWorkspace {
    private(set) var openCount = 0
    private(set) var webCount = 0
    private var success = true
    func setSuccess(_ value: Bool) { success = value }
    func resolveApplication(_ name: String) -> URL? {
        name == "missing" ? nil : URL(fileURLWithPath: "/Applications/Fake.app")
    }
    func openApplication(_ url: URL) async throws -> Bool { try Task.checkCancellation(); openCount += 1; return success }
    func activateApplication(_ url: URL) async throws -> Bool { try Task.checkCancellation(); return success }
    func quitApplication(_ url: URL) async throws -> Bool { try Task.checkCancellation(); return success }
    func openWebURL(_ url: URL) throws -> Bool { try Task.checkCancellation(); webCount += 1; return success }
}
