import Foundation

extension JarvisApp {
    // MARK: Allowlisted Apple Shortcuts (P2)

    func loadAllowlistedShortcuts() {
        store.allowlistedShortcuts = executor.appleShortcutBridge?.allowlist() ?? []
    }

    func refreshMacShortcuts() {
        guard !store.shortcutsLoading else { return }
        guard let bridge = executor.appleShortcutBridge else {
            store.shortcutsStatus = "Модуль Apple Shortcuts не підключено."
            return
        }
        store.shortcutsLoading = true
        store.shortcutsStatus = "Завантажую список команд із Mac…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let names = try await bridge.listAvailableShortcuts()
                self.store.availableMacShortcuts = names
                self.store.shortcutsStatus = names.isEmpty
                    ? "У програмі «Швидкі команди» (Shortcuts) на цьому Mac поки немає команд."
                    : "Знайдено команд на Mac: \(names.count)."
            } catch {
                self.store.shortcutsStatus = "Не вдалося отримати список із /usr/bin/shortcuts."
            }
            self.store.shortcutsLoading = false
        }
    }

    func addAllowlistedShortcut(name: String, aliasUK: String, aliasEN: String, requiresConfirmation: Bool) {
        guard let bridge = executor.appleShortcutBridge else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppleShortcutAllowlistStore.isValidShortcutName(trimmed) else {
            store.shortcutsStatus = "Некоректна назва команди."
            return
        }
        var current = bridge.allowlist()
        let uk = aliasUK.split(separator: ",").map(String.init)
        let en = aliasEN.split(separator: ",").map(String.init)
        let entry = AllowlistedShortcut(
            name: trimmed,
            aliasesUK: AppleShortcutAllowlistStore.sanitizeAliases(uk),
            aliasesEN: AppleShortcutAllowlistStore.sanitizeAliases(en),
            requiresConfirmation: requiresConfirmation
        )
        if let idx = current.firstIndex(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            current[idx] = entry
        } else {
            current.append(entry)
        }
        do {
            try bridge.store.save(current)
            store.allowlistedShortcuts = bridge.allowlist()
            store.shortcutsStatus = "Збережено «\(trimmed)» у білому списку."
        } catch {
            store.shortcutsStatus = "Не вдалося зберегти білий список Shortcuts."
        }
    }

    func updateAllowlistedShortcut(_ entry: AllowlistedShortcut) {
        guard let bridge = executor.appleShortcutBridge else { return }
        var current = bridge.allowlist()
        guard let idx = current.firstIndex(where: { $0.name.lowercased() == entry.name.lowercased() }) else { return }
        current[idx] = entry
        do {
            try bridge.store.save(current)
            store.allowlistedShortcuts = bridge.allowlist()
            store.shortcutsStatus = "Оновлено налаштування «\(entry.name)»."
        } catch {
            store.shortcutsStatus = "Не вдалося оновити білий список Shortcuts."
        }
    }

    func removeAllowlistedShortcut(named name: String) {
        guard let bridge = executor.appleShortcutBridge else { return }
        var current = bridge.allowlist()
        current.removeAll { $0.name.lowercased() == name.lowercased() }
        do {
            try bridge.store.save(current)
            store.allowlistedShortcuts = bridge.allowlist()
            store.shortcutsStatus = "Видалено «\(name)» із білого списку."
        } catch {
            store.shortcutsStatus = "Не вдалося видалити команду зі списку."
        }
    }
}
