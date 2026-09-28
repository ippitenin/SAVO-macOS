import Foundation
import Combine

/// Настройки приложения поверх UserDefaults. Все свойства @Published —
/// SwiftUI-вью подписываются напрямую.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let downloadsFolderPath = "downloadsFolderPath"
        static let autoPasteFromClipboard = "autoPasteFromClipboard"
        static let autoUpdateEngine = "autoUpdateEngine"
    }

    private let defaults = UserDefaults.standard

    /// Папка, куда складываются скачанные файлы. По умолчанию — «Загрузки».
    @Published var downloadsFolder: URL {
        didSet { defaults.set(downloadsFolder.path, forKey: Keys.downloadsFolderPath) }
    }

    /// Автоподхват YouTube-ссылки из буфера при активации приложения.
    /// По умолчанию ВЫКЛЮЧЕН: вставка без спроса воспринимается как
    /// самоуправство — пользователь включает осознанно в настройках.
    @Published var autoPasteFromClipboard: Bool {
        didSet { defaults.set(autoPasteFromClipboard, forKey: Keys.autoPasteFromClipboard) }
    }

    /// Раз в сутки проверять новую версию yt-dlp и ставить её самим.
    /// По умолчанию ВКЛЮЧЕНО: YouTube часто меняет защиту, устаревший
    /// движок — главная причина отказов.
    @Published var autoUpdateEngine: Bool {
        didSet { defaults.set(autoUpdateEngine, forKey: Keys.autoUpdateEngine) }
    }

    private init() {
        if let path = defaults.string(forKey: Keys.downloadsFolderPath) {
            downloadsFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            downloadsFolder = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true)
        }
        autoPasteFromClipboard = defaults.object(forKey: Keys.autoPasteFromClipboard) as? Bool ?? false
        autoUpdateEngine = defaults.object(forKey: Keys.autoUpdateEngine) as? Bool ?? true
    }
}
