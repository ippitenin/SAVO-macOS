import AppKit

// Top-level код не изолирован на MainActor, но приложение стартует на главном потоке.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Обычное оконное приложение с иконкой в Dock.
    app.setActivationPolicy(.regular)
    app.run()
}
