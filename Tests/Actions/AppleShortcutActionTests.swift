import Foundation
import Darwin

@MainActor
private final class FakeAppleShortcutRunner: AppleShortcutRunning {
    var available: [String] = []
    private(set) var ran: [String] = []
    var behavior: (String, TimeInterval) async throws -> Void = { _, _ in }

    func runShortcut(named exactName: String, timeoutSeconds: TimeInterval) async throws {
        ran.append(exactName)
        try await behavior(exactName, timeoutSeconds)
    }

    func listShortcuts() async throws -> [String] {
        available
    }
}

@MainActor
private final class DummyWorkspace: ActionWorkspace {
    func resolveApplication(_ name: String) -> URL? { nil }
    func openApplication(_ url: URL) async throws -> Bool { false }
    func activateApplication(_ url: URL) async throws -> Bool { false }
    func quitApplication(_ url: URL) async throws -> Bool { false }
    func openWebURL(_ url: URL) throws -> Bool { false }
}

@main struct AppleShortcutActionTests {
    static func main() async throws {
        var count = 0
        func check(_ ok: Bool, _ label: String) {
            guard ok else { fatalError("FAIL: \(label)") }
            count += 1
        }

        let tmpRoot = URL(fileURLWithPath: "/tmp/jarvis-apple-shortcut-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // 1. Empty allowlist by default when file does not exist.
        let storeURL = tmpRoot.appendingPathComponent("config/shortcuts-allowlist.json")
        let store = AppleShortcutAllowlistStore(fileURL: storeURL)
        check(store.load().isEmpty, "Allowlist is empty by default")

        let runner = await MainActor.run { FakeAppleShortcutRunner() }
        let bridge = AppleShortcutActions(store: store, runner: runner, timeoutSeconds: 0.25)

        // 2. Rejects any command not in allowlist.
        let denied = await bridge.perform(.runShortcut("Dark Mode"), language: "uk")
        if case .failed(let reason) = denied {
            check(reason.contains("білого списку"), "Non-allowlisted shortcut rejected in uk")
        } else { check(false, "Expected failure for non-allowlisted shortcut") }
        check(await MainActor.run { runner.ran.isEmpty }, "Runner never called for non-allowlisted shortcut")

        // 3. Injection names (including CLI flags) rejected by ActionRegistry and store.save.
        let registry = ActionRegistry()
        let badNames = ["", "   ", "-i", "--help", "--input-path", "; rm -rf /", "../etc/passwd", "foo/bar", "line1\nline2", "a|b", "test$HOME", "`id`", "a&b"]
        for bad in badNames {
            do {
                try registry.validate(.runShortcut(bad))
                check(false, "Registry should reject \(bad)")
            } catch ActionError.invalidParameters {
                count += 1
            }
            do {
                try store.save([AllowlistedShortcut(name: bad)])
                check(false, "Store should reject \(bad)")
            } catch AppleShortcutError.invalidName {
                count += 1
            }
        }

        // 4. Save allowlist: verify 0700 dir and 0600 file permissions, plus round-trip.
        let entries = [
            AllowlistedShortcut(
                name: "Connect AirPods",
                aliasesUK: ["підключи AirPods", "підключи аірподс"],
                aliasesEN: ["connect airpods"],
                requiresConfirmation: false
            ),
            AllowlistedShortcut(
                name: "Work VPN",
                aliasesUK: ["увімкни робочий VPN"],
                aliasesEN: ["enable work vpn"],
                requiresConfirmation: true
            ),
        ]
        try store.save(entries)
        var fileStat = stat()
        check(lstat(storeURL.path, &fileStat) == 0, "Allowlist file exists")
        check((fileStat.st_mode & 0o777) == 0o600, "Allowlist file has 0600 permissions")
        var dirStat = stat()
        check(lstat(storeURL.deletingLastPathComponent().path, &dirStat) == 0, "Allowlist dir exists")
        check((dirStat.st_mode & 0o777) == 0o700, "Allowlist dir has 0700 permissions")
        check(store.load() == entries, "Allowlist round-trips cleanly")

        // 5. Symlink rejection on store file path.
        let symlinkTarget = tmpRoot.appendingPathComponent("real-target.json")
        FileManager.default.createFile(atPath: symlinkTarget.path, contents: Data("[]".utf8))
        let symlinkPath = tmpRoot.appendingPathComponent("config/symlink-allowlist.json")
        check(symlink(symlinkTarget.path, symlinkPath.path) == 0, "Created test symlink")
        let symlinkStore = AppleShortcutAllowlistStore(fileURL: symlinkPath)
        check(symlinkStore.load().isEmpty, "Symlink allowlist load safely returns empty")
        // Rename atomically replaces symlink or fails on parent symlink; test parent symlink rejection:
        let symlinkDir = tmpRoot.appendingPathComponent("symlink-dir")
        check(symlink(tmpRoot.appendingPathComponent("config").path, symlinkDir.path) == 0, "Created symlink dir")
        let dirSymlinkStore = AppleShortcutAllowlistStore(fileURL: symlinkDir.appendingPathComponent("allowlist.json"))
        do {
            try dirSymlinkStore.save([AllowlistedShortcut(name: "Safe")])
            check(false, "Parent symlink directory must be rejected")
        } catch AppleShortcutError.unsafePath {
            count += 1
        }

        // 6. Effective policy (.immediate vs .confirmation) and registry default (.confirmation).
        check(registry.policy(for: .runShortcut("Connect AirPods")) == .confirmation, "Registry defaults to confirmation")
        let pImmediate = await MainActor.run { bridge.effectivePolicy(for: .runShortcut("Connect AirPods")) }
        let pConfirm = await MainActor.run { bridge.effectivePolicy(for: .runShortcut("Work VPN")) }
        let pUnknown = await MainActor.run { bridge.effectivePolicy(for: .runShortcut("Unknown")) }
        check(pImmediate == .immediate, "Allowlisted immediate shortcut policy")
        check(pConfirm == .confirmation, "Allowlisted confirmation shortcut policy")
        check(pUnknown == .confirmation, "Unknown shortcut defaults to confirmation")

        // 7. IntentParser triggers + Executor direct alias matching + HistoryStore privacy (no shortcut name persisted).
        let parser = IntentParser()
        check(parser.parse("Запусти команду Connect AirPods.", language: "uk") == .runShortcut("Connect AirPods"), "uk trigger parsed")
        check(parser.parse("запусти шорткат Work VPN!", language: "uk") == .runShortcut("Work VPN"), "uk shortcut trigger parsed")
        check(parser.parse("Run shortcut Connect AirPods.", language: "en") == .runShortcut("Connect AirPods"), "en trigger parsed")
        check(parser.parse("Запусти команду Connect AirPods", language: "ru") == nil, "Unsupported language rejected")

        let historyDir = tmpRoot.appendingPathComponent("history", isDirectory: true)
        let history = try HistoryStore(directory: historyDir)
        let dummyWorkspace = await MainActor.run { DummyWorkspace() }
        let executor = ActionExecutor(workspace: dummyWorkspace, history: history, appleShortcuts: bridge)

        // Direct uk alias runs immediately ($0 local).
        let aliasUKResult = await executor.handle("Підключи AirPods.", language: "uk")
        if case .done(let summary) = aliasUKResult {
            check(summary.contains("Connect AirPods"), "uk direct alias executed exact allowlisted name")
        } else { check(false, "Expected done for uk direct alias, got \(aliasUKResult)") }

        // Direct en alias runs immediately.
        let aliasENResult = await executor.handle("connect airpods", language: "en")
        if case .done(let summary) = aliasENResult {
            check(summary.contains("Connect AirPods"), "en direct alias executed")
        } else { check(false, "Expected done for en direct alias") }

        // Shortcut requiring confirmation returns .needsApproval from handle(_ text:) without running.
        let beforeConfirmCount = await MainActor.run { runner.ran.count }
        let confirmResult = await executor.handle("Увімкни робочий VPN", language: "uk")
        if case .needsApproval(let req) = confirmResult {
            check(req.action == .runShortcut("Work VPN"), "Confirmation shortcut yields needsApproval")
        } else { check(false, "Expected needsApproval for confirmation shortcut, got \(confirmResult)") }
        check(await MainActor.run { runner.ran.count } == beforeConfirmCount, "Confirmation shortcut did not execute yet")

        // Verify HistoryStore does not leak shortcut name or parameters.
        let records = try await history.read()
        check(records.count == 2, "Two executed shortcuts logged in history")
        check(records.allSatisfy { $0.action == "runShortcut" && $0.command == "runShortcut" && $0.result == "done" }, "History only stores kind/status")
        let rawHistory = try String(contentsOf: historyDir.appendingPathComponent("history.jsonl"), encoding: .utf8)
        check(!rawHistory.contains("AirPods") && !rawHistory.contains("VPN"), "History file leaks zero shortcut names")

        // 8. Timeout handling.
        await MainActor.run {
            runner.behavior = { _, _ in throw AppleShortcutError.timedOut }
        }
        let timedOut = await executor.handle(action: .runShortcut("Connect AirPods"), language: "en")
        if case .failed(let reason) = timedOut {
            check(reason.contains("timed out"), "Timeout reported clearly")
        } else { check(false, "Expected timeout failure") }

        // 9. Task cancellation handling.
        await MainActor.run {
            runner.behavior = { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        let cancelTask = Task {
            await executor.handle(action: .runShortcut("Connect AirPods"), language: "uk")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        cancelTask.cancel()
        let cancelOutcome = await cancelTask.value
        if case .failed(let reason) = cancelOutcome {
            check(reason.contains("скасовано"), "Cancelled task reported cleanly")
        } else { check(false, "Expected cancelled failure, got \(cancelOutcome)") }

        print("Apple shortcut action tests: \(count) checks passed")
    }
}
