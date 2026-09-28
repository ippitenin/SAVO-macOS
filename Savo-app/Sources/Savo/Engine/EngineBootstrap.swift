import Foundation

/// Запуск движка при старте приложения: установка рабочей копии в фоне,
/// затем (раз в сутки, если включено) автопроверка обновления. Первая
/// установка onedir — распаковка и проверочный запуск, секунды; ссылка,
/// вставленная в это время, ждёт окончания (waitUntilInstalled), а не
/// получает «движок не найден».
@MainActor
final class EngineBootstrap {
    static let shared = EngineBootstrap()

    private var installTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard installTask == nil else { return }
        // Освободился движок — применить обновление, скачанное, пока он был занят.
        EngineGate.shared.setOnIdle {
            Task { @MainActor in EngineStatus.shared.applyPendingIfAny() }
        }
        let task = Task.detached(priority: .utility) {
            await EngineInstaller.installIfNeeded()
        }
        installTask = task
        Task {
            await task.value
            EngineStatus.shared.refreshVersion()
            await checkForUpdatesIfDue()
        }
    }

    /// Дождаться окончания установки (мгновенно, если она уже прошла).
    func waitUntilInstalled() async {
        await installTask?.value
    }

    /// Автопроверка: включена в настройках и прошли сутки с прошлой.
    func checkForUpdatesIfDue() async {
        await waitUntilInstalled()
        guard SettingsStore.shared.autoUpdateEngine,
              EngineUpdater.isDue(lastCheck: EngineStatus.shared.lastCheck, now: Date())
        else { return }
        await EngineStatus.shared.update(manual: false)
    }
}
