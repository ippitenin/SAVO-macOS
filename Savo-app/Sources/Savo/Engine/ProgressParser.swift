import Foundation

/// Снимок прогресса загрузки для UI.
struct DownloadProgress: Equatable {
    /// Доля 0…1; nil — прогресс неопределён.
    var fraction: Double?
    /// Скорость, байт/с.
    var speed: Double?
    /// Осталось секунд.
    var eta: Double?
    /// Номер текущего этапа (видео/аудио) и их число.
    var phase: Int = 1
    var phaseCount: Int = 1
    /// Идёт объединение дорожек (ffmpeg) после скачивания.
    var merging: Bool = false
}

/// Снимок прогресса из машиночитаемой строки yt-dlp
/// (`--progress-template "download:%(progress)j"`).
struct ProgressSnapshot: Decodable {
    let status: String?
    let downloadedBytes: Double?
    let totalBytes: Double?
    let totalBytesEstimate: Double?
    let speed: Double?
    let eta: Double?
    let fragmentIndex: Double?
    let fragmentCount: Double?

    enum CodingKeys: String, CodingKey {
        case status, speed, eta
        case downloadedBytes = "downloaded_bytes"
        case totalBytes = "total_bytes"
        case totalBytesEstimate = "total_bytes_estimate"
        case fragmentIndex = "fragment_index"
        case fragmentCount = "fragment_count"
    }
}

/// Разбор строк прогресса. Чистая логика, тестируется без запуска движка.
enum ProgressParser {
    /// Префикс строк прогресса в stdout. ВАЖНО: в самом шаблоне yt-dlp
    /// «download:» — селектор типа прогресса и в вывод не попадает,
    /// поэтому шаблон — "download:savo:%(progress)j".
    static let linePrefix = "savo:"

    /// Regex для голых NaN-токенов: yt-dlp может выплюнуть NaN во
    /// float-полях, а JSONDecoder на них падает. Заменяем на null
    /// только после «:» или «,» — внутри строк (имя файла) не трогаем.
    private static let nanPattern = try! NSRegularExpression(pattern: #"(?<=[:,\[])\s*NaN"#)

    /// Снимок из строки stdout или nil, если это не строка прогресса.
    static func parse(line: String) -> ProgressSnapshot? {
        guard line.hasPrefix(linePrefix) else { return nil }
        var json = String(line.dropFirst(linePrefix.count))
        json = nanPattern.stringByReplacingMatches(
            in: json, range: NSRange(json.startIndex..., in: json), withTemplate: " null"
        )
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProgressSnapshot.self, from: data)
    }

    /// Доля 0…1: по байтам, иначе по фрагментам (HLS-эфиры без total),
    /// иначе nil — индетерминированный прогресс.
    static func fraction(of snapshot: ProgressSnapshot) -> Double? {
        if let total = snapshot.totalBytes ?? snapshot.totalBytesEstimate, total > 0,
           let done = snapshot.downloadedBytes {
            return min(1, done / total)
        }
        if let count = snapshot.fragmentCount, count > 0,
           let index = snapshot.fragmentIndex {
            return min(1, index / count)
        }
        return nil
    }
}

/// Агрегатор строк вывода yt-dlp в снимки DownloadProgress:
/// следит за фазами (видео → аудио), объединением и финальным путём файла.
struct DownloadProgressAggregator {
    /// Ожидаемое число фаз скачивания (видео+звук = 2).
    let phaseCount: Int
    private(set) var progress: DownloadProgress
    /// Финальный путь файла из `--print after_move:filepath`.
    private(set) var filePath: String?

    private var finishedPhases = 0

    init(phaseCount: Int) {
        self.phaseCount = phaseCount
        progress = DownloadProgress(fraction: nil, speed: nil, eta: nil,
                                    phase: 1, phaseCount: phaseCount, merging: false)
    }

    /// Обрабатывает строку stdout; true — если прогресс изменился.
    mutating func handle(line: String) -> Bool {
        if let snapshot = ProgressParser.parse(line: line) {
            switch snapshot.status {
            case "downloading":
                progress.fraction = ProgressParser.fraction(of: snapshot)
                progress.speed = snapshot.speed
                progress.eta = snapshot.eta
                progress.merging = false
                return true
            case "finished":
                finishedPhases += 1
                if finishedPhases >= phaseCount {
                    // Все дорожки скачаны — дальше работает ffmpeg.
                    progress.merging = true
                } else {
                    progress.phase = finishedPhases + 1
                    progress.fraction = nil
                    progress.speed = nil
                    progress.eta = nil
                }
                return true
            default:
                return false
            }
        }
        // Не прогресс: абсолютный путь — кандидат в финальный файл.
        if line.hasPrefix("/") {
            filePath = line
        }
        return false
    }
}
