import AppKit
import SwiftUI

/// Asks the owner before Jarvis reads a window whose text would go to the
/// cloud model (anything outside the allowlisted local utilities). One
/// question per request; no answer within `timeout`, Esc or closing the
/// panel all mean "no". The panel never becomes key, so focus stays put.
@MainActor final class SnapshotConsentPanel: NSObject, ObservableObject, NSWindowDelegate {
    struct ClipboardSummary {
        let characterCount: Int
        let preview: String
        let secretsMasked: Bool
    }

    let appName: String
    let request: String
    let language: String
    let clipboard: ClipboardSummary?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var panel: NSPanel?
    private var timer: Timer?

    init(appName: String, request: String, language: String, clipboard: ClipboardSummary? = nil) {
        self.appName = appName
        self.request = request
        self.language = language == "en" ? "en" : "uk"
        self.clipboard = clipboard
    }

    /// Shows the question and waits for the owner. Always returns exactly once.
    func ask(timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let window = ConsentWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250),
                                       styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                                       backing: .buffered, defer: false)
            window.title = actionText(language, "Дозвіл Jarvis", "Jarvis permission")
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.020, green: 0.039, blue: 0.063, alpha: 1)
            window.contentView = FirstMouseHostingView(rootView: SnapshotConsentView(model: self))
            window.delegate = self
            window.center()
            panel = window
            window.orderFrontRegardless()
            timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.answer(false) }
            }
        }
    }

    func answer(_ allowed: Bool) {
        timer?.invalidate()
        timer = nil
        let continuation = self.continuation
        self.continuation = nil
        if let panel {
            panel.delegate = nil
            panel.contentView = nil
            panel.close()
            self.panel = nil
        }
        continuation?.resume(returning: allowed)
    }

    /// Esc, a new turn or the microphone switched off.
    func cancel() { answer(false) }

    func windowWillClose(_ notification: Notification) { answer(false) }
}

private final class ConsentWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private struct SnapshotConsentView: View {
    @ObservedObject var model: SnapshotConsentPanel
    private let cyan = Color(red: 0.204, green: 0.902, blue: 0.941)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let clip = model.clipboard {
                Text(actionText(model.language, "ПРОЧИТАТИ БУФЕР ОБМІНУ?", "READ THE CLIPBOARD?"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(cyan)
                Text(actionText(model.language,
                                "Jarvis хоче передати текст із буфера (\(clip.characterCount) симв.) в OpenAI для запиту:",
                                "Jarvis wants to send clipboard text (\(clip.characterCount) chars) to OpenAI for the request:"))
                    .font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("«\(clip.preview)»")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                if clip.secretsMasked {
                    Text(actionText(model.language, "Увага: виявлені секрети/токени автоматично замасковано.", "Note: detected secrets/tokens were automatically masked."))
                        .font(.system(size: 12)).foregroundStyle(Color.orange)
                }
            } else {
                Text(actionText(model.language, "ПРОЧИТАТИ ВІКНО?", "READ THE WINDOW?"))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(cyan)
                Text(actionText(model.language,
                                "Jarvis хоче прочитати вікно «\(model.appName)» і передати його текст в OpenAI, щоб виконати запит:",
                                "Jarvis wants to read the ‘\(model.appName)’ window and send its text to OpenAI for the request:"))
                    .font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("«\(model.request)»")
                    .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(actionText(model.language, "Дозволити один раз", "Allow once")) { model.answer(true) }
                    .buttonStyle(.borderedProminent).tint(cyan)
                    .foregroundStyle(Color(red: 0.020, green: 0.039, blue: 0.063))
                Button(actionText(model.language, "Ні", "No")) { model.answer(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(actionText(model.language, "Без відповіді 30 с — ні", "No answer in 30 s means no"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520, height: 250, alignment: .topLeading)
        .preferredColorScheme(.dark)
    }
}
