import Foundation

/// Сбой подготовки движка из архива.
enum EngineArchiveError: Error, CustomStringConvertible {
    case extractFailed(String)
    case badLayout
    case launchFailed(String)
    case versionMismatch(expected: String, got: String)

    var description: String {
        switch self {
        case .extractFailed(let details): return "распаковка не удалась: \(details)"
        case .badLayout: return "в архиве нет yt-dlp_macos и _internal/"
        case .launchFailed(let details): return "проверочный запуск не удался: \(details)"
        case .versionMismatch(let expected, let got): return "ожидалась версия \(expected), получена \(got)"
        }
    }
}

/// Подготовка onedir-сборки yt-dlp из архива релиза: общий путь для
/// установки из бандла и для обновления. Результат — проверенный каталог
/// в staging, готовый к атомарной подмене рабочей копии.
enum EngineArchive {
    /// Итог подготовки.
    struct Prepared {
        /// Каталог с yt-dlp_macos, _internal/ и файлом VERSION.
        let dir: URL
        let version: String
        /// Время проверочного запуска. Первый запуск свежих бинарников
        /// дорогой (macOS проверяет их один раз), дальше — доли секунды.
        let launchSeconds: Double
    }

    /// Предел распаковки (124 МБ — секунды на SSD, с большим запасом).
    static let extractTimeout: Duration = .seconds(60)
    /// Предел проверочного запуска: первый старт свежих бинарников дорогой
    /// (macOS проверяет их один раз; на M5 Pro — 7,8 с), берём с запасом.
    static let launchTimeout: Duration = .seconds(120)

    /// zip → staging/<uuid>/yt-dlp_macos (ditto без карантина) → проверка
    /// раскладки → права → снятие карантина → `--version` → VERSION.
    /// `expectedVersion` — версия, которую обязан сообщить движок
    /// (защита от подсунутого или перепутанного архива).
    static func prepare(
        zip: URL,
        layout: EngineLayout,
        expectedVersion: String?
    ) async throws -> Prepared {
        let fm = FileManager.default
        let root = layout.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = root.appendingPathComponent(EngineLayout.onedirName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            // ditto, а не unzip: сохраняет симлинки и права; --noqtn — не
            // переносить карантин архива на распакованные файлы.
            let extract = try await ProcessRunner.runCollecting(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", "--noqtn", zip.path, dir.path],
                timeout: extractTimeout
            )
            guard extract.code == 0 else {
                throw EngineArchiveError.extractFailed(
                    extract.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let executable = dir.appendingPathComponent(EngineLayout.onedirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: executable.path),
                  fm.fileExists(atPath: dir.appendingPathComponent("_internal").path,
                                isDirectory: &isDir), isDir.boolValue else {
                throw EngineArchiveError.badLayout
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            stripQuarantine(under: dir)

            let started = ContinuousClock.now
            let check: (stdout: Data, stderr: String, code: Int32)
            do {
                check = try await ProcessRunner.runCollecting(
                    executable, arguments: ["--ignore-config", "--version"],
                    timeout: launchTimeout
                )
            } catch is ProcessTimeoutError {
                throw EngineArchiveError.launchFailed("нет ответа за \(launchTimeout)")
            }
            let seconds = EngineLog.seconds(since: started)
            let version = String(data: check.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard check.code == 0, let parsed = EngineVersion(version) else {
                throw EngineArchiveError.launchFailed(
                    "код \(check.code): \(check.stderr.suffix(300))")
            }
            if let expectedVersion, EngineVersion(expectedVersion) != parsed {
                throw EngineArchiveError.versionMismatch(expected: expectedVersion, got: version)
            }
            try Data(version.utf8).write(to: dir.appendingPathComponent("VERSION"), options: .atomic)
            return Prepared(dir: dir, version: version, launchSeconds: seconds)
        } catch {
            // Неудача не оставляет полураспакованных огрызков.
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Снимает com.apple.quarantine со всего дерева: с карантином
    /// Gatekeeper откажется запускать библиотеки из _internal.
    /// Без внешних процессов — обход FileManager + removexattr.
    static func stripQuarantine(under root: URL) {
        removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for case let url as URL in enumerator {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}
