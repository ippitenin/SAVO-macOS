import Foundation

/// Решение установщика для yt-dlp.
enum EngineInstallAction: Equatable {
    /// Применить проверенную отложенную версию (скачана обновлением,
    /// пока движок был занят).
    case applyPending
    /// Отложенная версия не новее рабочей — выбросить.
    case discardPending
    /// Развернуть onedir-архив из бандла.
    case installFromBundle
}

/// Установка рабочей копии движка при запуске: onedir yt-dlp из архива
/// в бандле, ffmpeg и deno — копией. Рабочая копия может быть НОВЕЕ бандла
/// (её обновляет EngineUpdater), поэтому бандл сравнивается с фактической
/// версией рабочей копии, а не с записанным когда-то базлайном.
enum EngineInstaller {
    /// Время проверочного запуска последней установки из бандла (отчёт).
    static let firstLaunchKey = "engineFirstLaunchSeconds"
    /// Ключ базлайна старой схемы (до onedir) — удаляется при миграции.
    private static let legacyBaselineKey = "engineBaselineVersion"

    /// Движок готов к работе: yt-dlp (onedir или старый onefile),
    /// ffmpeg и deno существуют и исполняемы.
    static var isInstalled: Bool { isReady(layout: .live) }

    static func isReady(layout: EngineLayout) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: layout.ytDlp.path)
            && fm.isExecutableFile(atPath: layout.ffmpeg.path)
            && fm.isExecutableFile(atPath: layout.deno.path)
    }

    /// Что сделать с yt-dlp. Чистая функция — главный объект харнесса.
    /// `current` — версия onedir рабочей копии (nil — onedir нет, не
    /// запускается или без VERSION: тогда ставится бандл).
    static func plan(
        current: EngineVersion?,
        pending: EngineVersion?,
        bundled: EngineVersion?
    ) -> [EngineInstallAction] {
        var actions: [EngineInstallAction] = []
        var effective = current
        if let pending {
            if effective.map({ pending > $0 }) ?? true {
                actions.append(.applyPending)
                effective = pending
            } else {
                actions.append(.discardPending)
            }
        }
        if let bundled, effective.map({ bundled > $0 }) ?? true {
            actions.append(.installFromBundle)
        }
        return actions
    }

    /// Версия onedir-каталога по его файлу VERSION (nil — каталога нет,
    /// исполняемый файл не запускаем или VERSION не читается).
    static func onedirVersion(in dir: URL) -> EngineVersion? {
        let executable = dir.appendingPathComponent(EngineLayout.onedirName)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let text = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8)
        else { return nil }
        return EngineVersion(text)
    }

    /// Установка/обновление рабочей копии. Сбой одного шага не валит
    /// остальные: рабочая копия остаётся прежней, причина — в журнале.
    static func installIfNeeded(layout: EngineLayout = .live) async {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.bin, withIntermediateDirectories: true)
            try fm.createDirectory(at: layout.tempDownloads, withIntermediateDirectories: true)
        } catch {
            EngineLog.event("установщик: не создать папки движка — \(error)")
            return
        }
        // Огрызки прерванной распаковки/обновления.
        try? fm.removeItem(at: layout.staging)

        let bundledArchive = layout.bundledArchive.flatMap {
            fm.fileExists(atPath: $0.path) ? $0 : nil
        }
        let bundledText = layout.bundledVersionFile.flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Архив без версии (или версия без архива) — бандл не участвует.
        let bundled = bundledArchive == nil ? nil : bundledText.flatMap(EngineVersion.init)

        let actions = plan(
            current: onedirVersion(in: layout.ytDlpDir),
            pending: onedirVersion(in: layout.pendingDir),
            bundled: bundled
        )
        for action in actions {
            switch action {
            case .applyPending:
                do {
                    try swapIn(layout.pendingDir, replacing: layout.ytDlpDir)
                    EngineLog.event("движок: применена отложенная версия \(onedirVersion(in: layout.ytDlpDir)?.description ?? "?")")
                } catch {
                    EngineLog.event("движок: не удалось применить отложенную версию — \(error)")
                }
            case .discardPending:
                try? fm.removeItem(at: layout.pendingDir)
            case .installFromBundle:
                guard let bundledArchive else { continue }
                do {
                    let prepared = try await EngineArchive.prepare(
                        zip: bundledArchive, layout: layout, expectedVersion: bundledText
                    )
                    try swapIn(prepared.dir, replacing: layout.ytDlpDir)
                    UserDefaults.standard.set(prepared.launchSeconds, forKey: firstLaunchKey)
                    EngineLog.event(String(
                        format: "движок: установлен %@ из бандла, первый запуск %.2fs",
                        prepared.version, prepared.launchSeconds))
                } catch {
                    EngineLog.event("движок: установка из бандла не удалась — \(error)")
                }
            }
        }

        // Миграция: старый onefile удаляем, только когда onedir уже
        // установлен и прошёл проверочный запуск на ЭТОМ Mac.
        if onedirVersion(in: layout.ytDlpDir) != nil,
           fm.fileExists(atPath: layout.legacyYtDlp.path) {
            try? fm.removeItem(at: layout.legacyYtDlp)
            UserDefaults.standard.removeObject(forKey: legacyBaselineKey)
            EngineLog.event("движок: старый onefile yt-dlp удалён")
        }

        copyIfChanged(layout.bundledFfmpeg, to: layout.ffmpeg)
        copyIfChanged(layout.bundledDeno, to: layout.deno)
        try? fm.removeItem(at: layout.staging)
    }

    /// Атомарная подмена каталога: rename с обменом (RENAME_SWAP) — один
    /// системный вызов, запущенный в этот момент код видит либо старый,
    /// либо новый каталог целиком. Возвращает путь, по которому после
    /// обмена лежит прежняя версия (nil — прежней не было).
    static func exchange(_ newDir: URL, into current: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else {
            try fm.moveItem(at: newDir, to: current)
            return nil
        }
        guard renamex_np(newDir.path, current.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return newDir
    }

    /// Подмена с немедленным удалением прежней версии (при запуске,
    /// когда движок гарантированно никто не использует).
    static func swapIn(_ newDir: URL, replacing current: URL) throws {
        if let old = try exchange(newDir, into: current) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Итог попытки применить отложенную версию.
    enum PendingResult: Equatable {
        case none
        case discarded
        /// Движок занят — применится, когда освободится.
        case busy
        case applied(String)
    }

    /// Применяет отложенную версию, если движок свободен: сам rename — под
    /// замком EngineGate, удаление прежней версии (сотня файлов) — в фоне.
    static func applyPendingIfIdle(
        layout: EngineLayout = .live,
        gate: EngineGate = .shared
    ) -> PendingResult {
        let fm = FileManager.default
        guard let pending = onedirVersion(in: layout.pendingDir) else {
            return .none
        }
        if let current = onedirVersion(in: layout.ytDlpDir), !(pending > current) {
            try? fm.removeItem(at: layout.pendingDir)
            return .discarded
        }
        var old: URL?
        var failure: Error?
        let ran = gate.performIfIdle {
            do {
                old = try exchange(layout.pendingDir, into: layout.ytDlpDir)
            } catch {
                failure = error
            }
        }
        guard ran else { return .busy }
        if let failure {
            EngineLog.event("движок: не удалось применить \(pending) — \(failure)")
            return .none
        }
        if let old { discardInBackground(old, layout: layout) }
        if fm.fileExists(atPath: layout.legacyYtDlp.path) {
            try? fm.removeItem(at: layout.legacyYtDlp)
        }
        EngineLog.event("движок: применена версия \(pending)")
        return .applied(pending.description)
    }

    /// Уносит каталог в staging (мгновенный rename) и удаляет его в фоне.
    private static func discardInBackground(_ url: URL, layout: EngineLayout) {
        let fm = FileManager.default
        try? fm.createDirectory(at: layout.staging, withIntermediateDirectories: true)
        let trash = layout.staging.appendingPathComponent("old-\(UUID().uuidString)")
        let target = (try? fm.moveItem(at: url, to: trash)) != nil ? trash : url
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Копия ffmpeg/deno из бандла, если в рабочей копии их нет или размер
    /// отличается (бандл новее). Карантин снимается: копия из скачанного
    /// бандла наследует атрибут, и Gatekeeper отказался бы её запускать.
    private static func copyIfChanged(_ source: URL?, to destination: URL) {
        let fm = FileManager.default
        guard let source, fm.fileExists(atPath: source.path) else { return }
        func size(_ url: URL) -> Int64? {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        }
        guard !fm.isExecutableFile(atPath: destination.path)
                || size(source) != size(destination) else { return }
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            removexattr(destination.path, "com.apple.quarantine", 0)
        } catch {
            EngineLog.event("движок: не удалось скопировать \(destination.lastPathComponent) — \(error)")
        }
    }
}
