import AppKit
import SwiftUI

extension JarvisApp {
    // MARK: Surfaces

    func makeMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Сховати Jarvis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершити Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Редагування")
        editMenu.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Вікно")
        windowMenu.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Jarvis"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.020, green: 0.039, blue: 0.063, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 680)
        window.contentView = FirstMouseHostingView(rootView: MainView(store: store, level: level, actions: actions))
        window.center()
        window.setFrameAutosaveName("JarvisMain")
        window.makeKeyAndOrderFront(nil)
    }

    func makeHUD() {
        hud = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hud.isFloatingPanel = true
        hud.level = .statusBar
        hud.hidesOnDeactivate = false
        hud.becomesKeyOnlyIfNeeded = true
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hud.title = "Jarvis HUD"
        hud.contentView = FirstMouseHostingView(rootView: HUDView(store: store, level: level, actions: actions))
    }

    func showHUD() {
        hudHide?.invalidate()
        hudHide = nil
        guard !hud.isVisible else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.minY + 36))
        }
        store.hudVisible = true
        hud.orderFrontRegardless() // never makeKey: the target field keeps focus
    }

    func hideHUD(after seconds: Double) {
        hudHide?.invalidate()
        guard hud.isVisible else { return }
        hudHide = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, !self.store.canCancel else { return }
            self.hud.orderOut(nil)
            self.store.hudVisible = false
            self.hudHide = nil
        }
    }

    func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let symbol: String
        switch store.phase {
        case .microphoneOff: symbol = "mic.slash"
        case .wakeListening: symbol = "ear"
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .error, .modelUnavailable: symbol = "exclamationmark.triangle"
        default: symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis: \(store.headline)")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Jarvis — \(store.headline)"
    }
}
