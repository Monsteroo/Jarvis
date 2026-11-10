import Foundation
import AppKit

@main struct DeviceActionTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { guard value else { fatalError(message) }; count += 1 }
        let screen = CGRect(x: -1200, y: 24, width: 1200, height: 776)
        check(WindowGeometry.destination(.windowLeftHalf, visibleFrame: screen) == CGRect(x: -1200, y: 24, width: 600, height: 776), "Left screen coordinates")
        check(WindowGeometry.destination(.windowRightHalf, visibleFrame: screen) == CGRect(x: -600, y: 24, width: 600, height: 776), "Right screen coordinates")
        check(WindowGeometry.destination(.windowMaximize, visibleFrame: screen) == screen, "Maximize respects visible frame")
        check(WindowGeometry.axFrame(fromAppKit: CGRect(x: 0, y: -800, width: 1200, height: 800), primaryTop: 900) == CGRect(x: 0, y: 900, width: 1200, height: 800), "Display below primary")
        let window = FakeWindow()
        let access = FakeWindowAccess(window)
        let actions = WindowActions(access: access)
        access.trusted = false
        if case .failed(let reason) = await actions.perform(.windowLeftHalf, language: "uk") {
            check(reason.contains("Доступність"), "Permission recovery instructions")
        } else { fatalError("Untrusted must fail") }
        check(window.writes == 0, "No change before permission")
        access.trusted = true
        if case .done = await actions.perform(.windowLeftHalf, language: "en") { count += 1 }
        else { fatalError("Left half must succeed") }
        check(window.frame == CGRect(x: 0, y: 0, width: 500, height: 700), "Verified half frame")
        window.allowSize = false
        let old = window.writes
        if case .failed = await actions.perform(.windowRightHalf, language: "uk") { count += 1 }
        else { fatalError("Unsupported preflight must fail") }
        check(window.writes == old, "Preflight avoids partial move")
        window.allowSize = true; window.ignoreSize = true
        if case .partial = await actions.perform(.windowMaximize, language: "uk") { count += 1 }
        else { fatalError("App constrained size must not report success") }
        window.ignoreSize = false
        if case .done = await actions.perform(.windowMinimize, language: "uk") { count += 1 }
        else { fatalError("Minimize readback") }
        check(window.minimized, "Minimized actually true")
        let audio = FakeOutput()
        let volume = AudioOutputActions(access: FakeAudioAccess(audio))
        if case .done = volume.perform(.volumeStep(10), language: "uk") { count += 1 }
        else { fatalError("Volume step") }
        check(abs(audio.values[0] - 0.6) < 0.001, "Step based on actual volume")
        _ = volume.perform(.volumeSet(100), language: "en")
        _ = volume.perform(.volumeStep(10), language: "en")
        check(audio.values == [1], "Clamp to max")
        _ = volume.perform(.mute(true), language: "uk")
        check(audio.muted, "Mute verified")
        audio.ignoreWrites = true
        if case .partial = volume.perform(.volumeSet(20), language: "en") { count += 1 }
        else { fatalError("Readback mismatch cannot succeed") }
        audio.available = false
        let writes = audio.writes
        if case .failed = volume.perform(.volumeSet(30), language: "uk") { count += 1 }
        else { fatalError("Device changed must fail") }
        check(audio.writes == writes, "Changed device not touched")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await actions.perform(.windowRightHalf, language: "uk")
        }
        let beforeCancel = window.writes
        if case .failed = await task.value { count += 1 } else { fatalError("Cancellation") }
        check(window.writes == beforeCancel, "Precancel no changes")
        window.throwPosition = true
        if case .partial = await actions.perform(.windowRightHalf, language: "en") { count += 1 }
        else { fatalError("Failed second write must be partial") }
        window.throwPosition = false
        audio.available = true; audio.ignoreWrites = false; audio.throwWrite = true
        if case .partial = volume.perform(.volumeSet(40), language: "uk") { count += 1 }
        else { fatalError("Partial channel write must be reported") }
        audio.throwWrite = false
        let handler = ActionExecutor(workspace: DeviceFakeWorkspace(), windows: actions, audioOutput: volume)
        if case .done = await handler.handle("гучність 30%", language: "uk") { count += 1 }
        else { fatalError("Executor routes volume") }
        if case .done = await handler.handle("move window right", language: "en") { count += 1 }
        else { fatalError("Executor routes windows") }
        let beforeBad = audio.writes
        if case .failed = await handler.handle("set volume to 120%", language: "en") { count += 1 }
        else { fatalError("Executor rejects volume outside range") }
        check(audio.writes == beforeBad, "Invalid request never reaches device")
        let soundTask = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return volume.perform(.mute(false), language: "uk")
        }
        if case .failed = await soundTask.value { count += 1 } else { fatalError("Sound precancel") }
        check(audio.writes == beforeBad, "Precancel does not touch sound")
        print("Device action tests: \(count) checks passed")
    }
}

@MainActor final class FakeWindow: WindowTarget {
    var frame = CGRect(x: 20, y: 20, width: 400, height: 300)
    var visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    var minimized = false
    var allowSize = true, ignoreSize = false, throwPosition = false
    var writes = 0
    func canSet(_ attribute: WindowAttribute) -> Bool { attribute != .size || allowSize }
    func readFrame() throws -> CGRect { frame }
    func readMinimized() throws -> Bool { minimized }
    func setPosition(_ point: CGPoint) throws { if throwPosition { throw DeviceActionError.writeFailed }; writes += 1; frame.origin = point }
    func setSize(_ size: CGSize) throws { writes += 1; if !ignoreSize { frame.size = size } }
    func setMinimized(_ value: Bool) throws { writes += 1; minimized = value }
}
@MainActor final class FakeWindowAccess: WindowAccess {
    var trusted = true
    let window: FakeWindow
    init(_ window: FakeWindow) { self.window = window }
    func target() throws -> WindowTarget { window }
}
@MainActor final class FakeOutput: OutputTarget {
    var values: [Float] = [0.5]
    var muted = false, available = true, ignoreWrites = false
    var writes = 0
    var throwWrite = false
    func isCurrent() -> Bool { available }
    func readVolumes() throws -> [Float] { values }
    func writeVolumes(_ values: [Float]) throws { writes += 1; if !ignoreWrites { self.values = values }; if throwWrite { throw DeviceActionError.writeFailed } }
    func readMute() throws -> Bool { muted }
    func writeMute(_ value: Bool) throws { writes += 1; if !ignoreWrites { muted = value } }
}
@MainActor struct FakeAudioAccess: OutputAccess {
    let output: FakeOutput
    init(_ output: FakeOutput) { self.output = output }
    func target() throws -> OutputTarget { output }
}

@MainActor final class DeviceFakeWorkspace: ActionWorkspace {
    func resolveApplication(_ name: String) -> URL? { nil }
    func openApplication(_ url: URL) async throws -> Bool { false }
    func activateApplication(_ url: URL) async throws -> Bool { false }
    func quitApplication(_ url: URL) async throws -> Bool { false }
    func openWebURL(_ url: URL) throws -> Bool { false }
}
