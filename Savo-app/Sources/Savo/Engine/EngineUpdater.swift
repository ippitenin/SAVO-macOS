import CryptoKit
import Foundation

/// Сбой обновления движка.
enum EngineUpdateError: Error, CustomStringConvertible {
    case network(String)
    case rateLimited
    case assetMissing
    case checksumMismatch

    var description: String {
        switch self {
        case .network(let details): return "сеть: \(details)"
        case .rateLimited: return "GitHub ограничил частоту запросов"
        case .assetMissing: return "в релизе нет yt-dlp_macos.zip или его суммы"
        case .checksumMismatch: return "SHA-256 архива не совпала с SHA2-256SUMS"
        }
    }
}

/// Собственный апдейтер yt-dlp. Замена `yt-dlp -U`: для onedir-сборки
/// (`darwin_dir`) yt-dlp самообновление не поддерживает. Путь: последний
/// релиз на GitHub → yt-dlp_macos.zip + SHA2-256SUMS → сверка SHA-256 →
/// EngineArchive.prepare (распаковка + проверочный запуск) → отложенный
/// каталог `yt-dlp_macos.pending`, который применяется, когда движок
/// свободен (EngineGate).
///
/// Подпись SHA2-256SUMS (GPG) не проверяется: сумма защищает целостность
/// загрузки, подлинность даёт HTTPS до github.com — для личного
/// приложения этого достаточно.
enum EngineUpdater {
    struct Release {
        let tag: String
        let zipURL: URL
        let sumsURL: URL
    }

    static let repo = "https://github.com/yt-dlp/yt-dlp"
    static let archiveName = EngineLayout.onedirName + ".zip"
    /// Как часто проверять автоматически.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Своя сессия: без кэша и с пределами времени — зависший запрос
    /// не должен вечно держать «Проверяю…».
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func release(tag: String) -> Release {
        let base = "\(repo)/releases/download/\(tag)/"
        return Release(
            tag: tag,
            zipURL: URL(string: base + archiveName)!,
            sumsURL: URL(string: base + "SHA2-256SUMS")!
        )
    }

    /// Последний стабильный релиз. Основной путь — HEAD на /releases/latest:
    /// GitHub перенаправляет на …/releases/tag/<тег>, а лимит API
    /// (60 запросов в час без токена) этого пути не касается.
    /// Запасной — api.github.com.
    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw EngineUpdateError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            try checkStatus(http.statusCode)
            if let url = http.url, url.path.contains("/releases/tag/"),
               EngineVersion(url.lastPathComponent) != nil {
                return release(tag: url.lastPathComponent)
            }
        }
        return release(tag: try await latestTagFromAPI())
    }

    private static func latestTagFromAPI() async throws -> String {
        struct Latest: Decodable { let tag_name: String }
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw EngineUpdateError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse { try checkStatus(http.statusCode) }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: data),
              EngineVersion(latest.tag_name) != nil else {
            throw EngineUpdateError.network("не удалось определить последний релиз")
        }
        return latest.tag_name
    }

    private static func checkStatus(_ code: Int) throws {
        switch code {
        case 200..<300: return
        case 403, 429: throw EngineUpdateError.rateLimited
        case 404: throw EngineUpdateError.assetMissing
        default: throw EngineUpdateError.network("HTTP \(code)")
        }
    }

    /// SHA-256 файла из SHA2-256SUMS (строки «<hex>  <имя>» или
    /// «<hex> *<имя>»). Чистая функция.
    static func parseChecksums(_ text: String, file: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == file else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return hash
        }
        return nil
    }

    /// SHA-256 файла, потоково (архив — 50+ МБ).
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Скачивает и проверяет релиз, кладёт готовый каталог в pendingDir.
    /// Возвращает версию. Рабочая копия не трогается.
    static func stage(_ release: Release, layout: EngineLayout) async throws -> String {
        let fm = FileManager.default
        let work = layout.staging.appendingPathComponent("download-\(UUID().uuidString)",
                                                         isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let sums = try await download(release.sumsURL, to: work.appendingPathComponent("SHA2-256SUMS"))
        guard let text = try? String(contentsOf: sums, encoding: .utf8),
              let expected = parseChecksums(text, file: archiveName) else {
            throw EngineUpdateError.assetMissing
        }
        let zip = try await download(release.zipURL, to: work.appendingPathComponent(archiveName))
        guard try sha256(of: zip) == expected else {
            throw EngineUpdateError.checksumMismatch
        }

        let prepared = try await EngineArchive.prepare(
            zip: zip, layout: layout, expectedVersion: release.tag
        )
        defer { try? fm.removeItem(at: prepared.dir.deletingLastPathComponent()) }
        try? fm.removeItem(at: layout.pendingDir)
        try fm.moveItem(at: prepared.dir, to: layout.pendingDir)
        return prepared.version
    }

    /// Загрузка файла: временный файл URLSession сразу переносится в
    /// `destination` (система удаляет его по выходе из вызова).
    private static func download(_ url: URL, to destination: URL) async throws -> URL {
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await session.download(from: url)
        } catch {
            throw EngineUpdateError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            do {
                try checkStatus(http.statusCode)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    /// Пора ли проверять: раз в `interval`. Дата в будущем (переведённые
    /// часы) — тоже пора, иначе проверка застряла бы надолго.
    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
