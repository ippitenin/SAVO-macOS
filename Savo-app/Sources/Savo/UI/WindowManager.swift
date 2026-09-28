import AppKit
import SwiftUI

/// Окна приложения: главное окно загрузчика и окно настроек.
/// Создаются лениво и переживают закрытие.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    /// Контроллер загрузки; назначает AppDelegate до первого showMain().
    weak var downloadController: DownloadController?

    private init() {}

    /// Открывает главное окно.
    func showMain() {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        guard let window = mainWindow else { return }
        if !window.isVisible {
            center(window)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Открывает окно настроек (Cmd+,).
    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        guard let window = settingsWindow else { return }
        if !window.isVisible {
            center(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindow() -> NSWindow {
        // Контроллер обязан существовать к моменту создания окна.
        let controller = downloadController ?? DownloadController()
        let hosting = NSHostingController(rootView: MainView(controller: controller))
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Тайтлбар скрыт: контент уходит под трафик-лайты, окно выглядит
        // единой стеклянной поверхностью. title остаётся — для Mission
        // Control и VoiceOver.
        window.title = L("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Пустой невидимый тулбар делает тайтлбар выше (52pt): трафик-лайты
        // опускаются к его центру и не липнут к самому углу.
        let toolbar = NSToolbar(identifier: "savo.main")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Перетаскивание — только за зону тайтлбара, как у обычных приложений.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        // Размер должен быть рассчитан ДО центрирования, иначе окно
        // центрируется с нулевым размером и «вырастает» из верхней точки.
        window.setContentSize(NSSize(width: 560, height: 720))
        window.minSize = NSSize(width: 520, height: 600)
        return window
    }

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("settings.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 500, height: 640))
        return window
    }

    /// Настоящий центр экрана с курсором (NSWindow.center() ставит окно
    /// в верхнюю треть и всегда на главный экран).
    private func center(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}
