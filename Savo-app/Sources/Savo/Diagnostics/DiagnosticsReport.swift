import Foundation

/// Факты для отчёта об отладке — плоские значения без UI.
struct DiagnosticsFacts {
    struct EngineFile {
        let name: String
        let sizeBytes: Int64?
    }
    struct RecentDownload {
        let date: Date
        let presetLabel: String
        let fileExists: Bool
        let fileName: String
    }

    var generatedAt = Date()
    var appVersion = "?"
    var appBuild = "?"
    var macOS = "?"
    var model = "?"
    var cpu = "?"
    var memoryBytes: UInt64 = 0

    var engineVersion: String?
    /// Раскладка движка: onefile / onedir.
    var engineLayout = "?"
    var engineFiles: [EngineFile] = []
    var quarantinedFiles = 0
    /// Замеры `yt-dlp --version` подряд, секунды (nil — запуск не удался).
    var launchSeconds: [Double?] = []
    /// Проверочный запуск при последней установке из бандла (первый,
    /// самый дорогой запуск свежих бинарников).
    var installLaunchSeconds: Double?
    var pendingVersion: String?
    var autoUpdate = true
    var lastUpdateCheck: Date?

    var downloadsFolder = "?"
    var downloadsWritable = false
    var freeBytes: Int64?

    var recent: [RecentDownload] = []
    var logTail = ""
}

/// Отчёт для отладки: одним нажатием — всё, что нужно, чтобы разобраться
/// со сбоем на другом Mac (версии, модель Mac, скорость старта движка,
/// последние загрузки, хвост журнала). Текст не локализуется — это не
/// интерфейс, а технический документ, как engine.log.
enum DiagnosticsReport {
    static let logLines = 150
    static let recentCount = 5

    /// Собирает факты. Два запуска `--version` подряд: первый показывает
    /// холодный старт, второй — тёплый.
    @MainActor
    static func collect() async -> DiagnosticsFacts {
        var f = DiagnosticsFacts()
        let info = Bundle.main.infoDictionary ?? [:]
        f.appVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        f.appBuild = info["CFBundleVersion"] as? String ?? "?"
        f.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        f.model = sysctlString("hw.model") ?? "?"
        f.cpu = sysctlString("machdep.cpu.brand_string") ?? "?"
        f.memoryBytes = ProcessInfo.processInfo.physicalMemory

        let fm = FileManager.default
        f.engineLayout = EnginePaths.layoutDescription
        f.engineFiles = [EnginePaths.workYtDlp, EnginePaths.workFfmpeg, EnginePaths.workDeno].map {
            let size = (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? nil
            return .init(name: $0.lastPathComponent, sizeBytes: size)
        }
        f.quarantinedFiles = quarantinedCount(under: EnginePaths.workBin)
        f.installLaunchSeconds = UserDefaults.standard.object(
            forKey: EngineInstaller.firstLaunchKey) as? Double
        f.pendingVersion = EngineStatus.shared.pendingVersion
        f.autoUpdate = SettingsStore.shared.autoUpdateEngine
        f.lastUpdateCheck = EngineStatus.shared.lastCheck
        let ytDlp = EnginePaths.workYtDlp
        if fm.isExecutableFile(atPath: ytDlp.path) {
            for _ in 0..<2 {
                let started = ContinuousClock.now
                let result = try? await EngineGate.shared.withLease {
                    try await ProcessRunner.runCollecting(ytDlp, arguments: ["--version"])
                }
                let seconds = EngineLog.seconds(since: started)
                if let result, result.code == 0 {
                    f.launchSeconds.append(seconds)
                    f.engineVersion = String(data: result.stdout, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    f.launchSeconds.append(nil)
                }
            }
        }

        let folder = SettingsStore.shared.downloadsFolder
        f.downloadsFolder = folder.path
        f.downloadsWritable = fm.isWritableFile(atPath: folder.path)
        f.freeBytes = (try? folder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage

        f.recent = HistoryStore.shared.records.prefix(recentCount).map {
            .init(date: $0.date, presetLabel: $0.presetLabel,
                  fileExists: $0.fileExists,
                  fileName: URL(fileURLWithPath: $0.filePath).lastPathComponent)
        }
        f.logTail = EngineLog.tail(lines: logLines)
        return f
    }

    /// Текст отчёта. Чистая функция.
    static func render(_ f: DiagnosticsFacts) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        func size(_ b: Int64?) -> String { b.map { bytes.string(fromByteCount: $0) } ?? "нет" }
        func home(_ path: String) -> String {
            path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        let launches = f.launchSeconds.isEmpty
            ? "не запускался"
            : f.launchSeconds.map { $0.map { String(format: "%.2f с", $0) } ?? "сбой" }
                .joined(separator: ", ")

        var lines = [
            "Savo — отчёт для отладки (\(stamp.string(from: f.generatedAt)))",
            "",
            "Приложение: \(f.appVersion) (\(f.appBuild))",
            "macOS: \(f.macOS)",
            "Модель: \(f.model) · \(f.cpu) · \(size(Int64(f.memoryBytes)))",
            "",
            "Движок",
            "  yt-dlp: \(f.engineVersion ?? "—") (\(f.engineLayout))",
        ]
        lines += f.engineFiles.map { "  \($0.name): \(size($0.sizeBytes))" }
        lines += [
            "  файлов с карантином: \(f.quarantinedFiles)",
            "  старт yt-dlp --version: \(launches)",
            "  первый запуск при установке: "
                + (f.installLaunchSeconds.map { String(format: "%.2f с", $0) } ?? "—"),
            "  ждёт применения: \(f.pendingVersion ?? "—")",
            "  автообновление: \(f.autoUpdate ? "вкл" : "выкл"), последняя проверка: "
                + (f.lastUpdateCheck.map { stamp.string(from: $0) } ?? "не было"),
            "",
            "Загрузки",
            "  папка: \(home(f.downloadsFolder))",
            "  запись: \(f.downloadsWritable ? "да" : "НЕТ"), свободно: \(size(f.freeBytes))",
            "",
            "Последние загрузки",
        ]
        if f.recent.isEmpty {
            lines.append("  —")
        }
        lines += f.recent.map {
            "  \(stamp.string(from: $0.date)) · \($0.presetLabel) · "
                + "\($0.fileExists ? "файл есть" : "ФАЙЛА НЕТ") · \($0.fileName)"
        }
        lines += ["", "Журнал движка (последние \(logLines) строк)", f.logTail]
        return lines.joined(separator: "\n")
    }

    // MARK: - Системные сведения

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Сколько файлов под `root` несут com.apple.quarantine: Gatekeeper
    /// блокирует запуск таких бинарников на втором Mac.
    static func quarantinedCount(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
        where getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            count += 1
        }
        return count
    }
}
