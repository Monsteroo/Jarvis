import AppKit
import SwiftUI

/// Floating HUD that never becomes key, so dictation targets keep focus.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Mic-off and cancel must react to the first click, even in an inactive window or the non-key HUD.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
