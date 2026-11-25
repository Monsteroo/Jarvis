import AppKit
import Foundation

/// Minimal self-contained Cocoa window for safe live verification of:
/// 1) AXPress on a synthetic button,
/// 2) AXSecureTextField non-reading policy,
/// 3) STALE_REF rejection when a button mutates after snapshot.
final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var actionButton: NSButton!
    var secureField: NSSecureTextField!
    var pressCount = 0
    let stateFile: String?

    init(stateFile: String?) {
        self.stateFile = stateFile
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 120, y: 120, width: 340, height: 180)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AXProbe Fixture"
        let content = NSView(frame: rect)

        statusLabel = NSTextField(labelWithString: "Clicks: 0")
        statusLabel.frame = NSRect(x: 20, y: 130, width: 280, height: 24)
        statusLabel.setAccessibilityIdentifier("fixture-status")

        actionButton = NSButton(title: "Increment", target: self, action: #selector(onPress))
        actionButton.frame = NSRect(x: 20, y: 80, width: 140, height: 32)
        actionButton.setAccessibilityIdentifier("fixture-btn")

        let mutateButton = NSButton(title: "Mutate Label", target: self, action: #selector(onMutate))
        mutateButton.frame = NSRect(x: 175, y: 80, width: 140, height: 32)
        mutateButton.setAccessibilityIdentifier("fixture-mutate")

        secureField = NSSecureTextField(frame: NSRect(x: 20, y: 30, width: 295, height: 26))
        secureField.stringValue = "top-secret-fixture-token-999"
        secureField.setAccessibilityIdentifier("fixture-password")

        content.addSubview(statusLabel)
        content.addSubview(actionButton)
        content.addSubview(mutateButton)
        content.addSubview(secureField)
        window.contentView = content
        window.orderFrontRegardless()
        writeState()

        // Auto-exit after 25s so a stray test fixture never lingers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc func onPress() {
        pressCount += 1
        statusLabel.stringValue = "Clicks: \(pressCount)"
        writeState()
    }

    @objc func onMutate() {
        actionButton.title = "Delete Everything"
        actionButton.setAccessibilityIdentifier("fixture-danger")
        writeState()
    }

    private func writeState() {
        guard let stateFile else { return }
        let text = "clicks=\(pressCount)\nbutton=\(actionButton.title)\n"
        try? text.write(toFile: stateFile, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let outPath = CommandLine.arguments.dropFirst().first
let delegate = FixtureAppDelegate(stateFile: outPath)
app.delegate = delegate
app.run()
