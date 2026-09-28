import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var downloadController: DownloadController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        downloadController = DownloadController()
        WindowManager.shared.downloadController = downloadController
        // Рабочая копия движка в Application Support (первый запуск или
        // обновление приложения) и автопроверка обновления — в фоне.
        EngineBootstrap.shared.start()
        WindowManager.shared.showMain()
    }

    /// Автоподхват YouTube-ссылки из буфера при переключении на Savo.
    func applicationDidBecomeActive(_ notification: Notification) {
        downloadController?.handleClipboardOnActivate()
        // Приложение может жить открытым сутками — проверка догонит.
        Task { await EngineBootstrap.shared.checkForUpdatesIfDue() }
    }

    /// Одноокна утилита: закрыл окно — приложение завершилось.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Повторный запуск (клик по иконке в Dock) открывает главное окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMain()
        return false
    }

    /// Полное главное меню: без пунктов «Правка» не работают Cmd+C/V/X/A,
    /// без «Окно» — Cmd+W/Cmd+M, App-меню даёт «Настройки…» и «Завершить».
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("menu.settings"),
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hideApp"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: L("menu.hideOthers"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: L("menu.showAll"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: L("edit.menu"))
        editMenu.addItem(withTitle: L("edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: L("window.menu"))
        windowMenu.addItem(withTitle: L("window.close"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("window.minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        WindowManager.shared.showSettings()
    }
}
