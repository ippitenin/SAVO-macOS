import Foundation

/// Версия и обновление движка для окна настроек. Обновление — собственный
/// апдейтер (EngineUpdater): onedir-сборка yt-dlp `-U` не поддерживает.
@MainActor
final class EngineStatus: ObservableObject {
    static let shared = EngineStatus()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(String)
        case installing
    }

    @Published private(set) var version: String?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastUpdateResult: String?
    /// Проверенная версия, ждущая, пока движок освободится.
    @Published private(set) var pendingVersion: String?
    @Published private(set) var lastCheck: Date?

    var updating: Bool { phase != .idle }

    private static let lastCheckKey = "engineLastUpdateCheck"
    private let layout = EngineLayout.live

    private init() {
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Версия рабочей копии: у onedir — из файла VERSION (мгновенно),
    /// у старого onefile — запуском `--version` (~7 с).
    func refreshVersion() {
        pendingVersion = EngineInstaller.onedirVersion(in: layout.pendingDir)?.description
        if let onedir = EngineInstaller.onedirVersion(in: layout.ytDlpDir) {
            version = onedir.description
            return
        }
        guard EngineInstaller.isInstalled else {
            version = nil
            return
        }
        let ytDlp = layout.ytDlp
        Task {
            let result = try? await EngineGate.shared.withLease {
                try await ProcessRunner.runCollecting(ytDlp, arguments: ["--version"])
            }
            guard let result, result.code == 0 else { return }
            version = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Проверка и установка обновления — единственный вход. `manual` —
    /// нажата кнопка: итог показывается в настройках; автопроверка
    /// молчит и пишет сбои только в журнал.
    func update(manual: Bool) async {
        guard phase == .idle else { return }
        if manual { lastUpdateResult = nil }
        phase = .checking
        defer { phase = .idle }
        do {
            let release = try await EngineUpdater.latestRelease()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)

            let current = EngineInstaller.onedirVersion(in: layout.ytDlpDir)
            let pending = EngineInstaller.onedirVersion(in: layout.pendingDir)
            let best = [current, pending].compactMap { $0 }.max()
            if let latest = EngineVersion(release.tag), let best, !(latest > best) {
                // Уже последняя (или уже скачана и ждёт своей очереди).
                applyPendingIfAny()
                if manual, pendingVersion == nil {
                    lastUpdateResult = L("settings.engine.upToDate")
                }
                return
            }
            phase = .downloading(release.tag)
            _ = try await EngineUpdater.stage(release, layout: layout)
            phase = .installing
            applyPendingIfAny()
        } catch {
            EngineLog.event("обновление движка не удалось — \(error)")
            if manual {
                lastUpdateResult = message(for: error)
            }
        }
    }

    /// Применяет отложенную версию, если движок свободен. Вызывается после
    /// загрузки обновления и каждый раз, когда движок освобождается.
    func applyPendingIfAny() {
        // Пока апдейтер пишет pendingDir, трогать его нельзя.
        if case .downloading = phase { return }
        switch EngineInstaller.applyPendingIfIdle(layout: layout) {
        case .none, .discarded:
            pendingVersion = nil
        case .busy:
            pendingVersion = EngineInstaller.onedirVersion(in: layout.pendingDir)?.description
            if let pendingVersion {
                lastUpdateResult = L("settings.engine.pending", pendingVersion)
            }
        case .applied(let applied):
            pendingVersion = nil
            version = applied
            lastUpdateResult = L("settings.engine.updatedTo", applied)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case EngineUpdateError.network, EngineUpdateError.rateLimited:
            return L("settings.engine.updateFailed.network")
        case EngineUpdateError.checksumMismatch:
            return L("settings.engine.updateFailed.checksum")
        default:
            return L("settings.engine.updateFailed")
        }
    }
}
