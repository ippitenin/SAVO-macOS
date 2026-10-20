import Foundation

/// Снимок прогресса загрузки для UI.
struct DownloadProgress: Equatable {
    /// Доля всего скачивания 0…1 (видео и звук — одна полоса);
    /// nil — прогресс неопределён.
    var fraction: Double?
    /// Скорость, байт/с.
    var speed: Double?
    /// Осталось секунд (по текущей дорожке).
    var eta: Double?
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

/// Агрегатор строк вывода yt-dlp в снимки DownloadProgress: сводит фазы
/// (видео → звук) в одну полосу, следит за объединением и финальным путём.
///
/// Каждая фаза занимает в полосе долю по своему весу (размер дорожки):
/// видео идёт почти до конца, звук досыпает остаток. Раньше полоса
/// доходила до 100% на видео и сбрасывалась на звуке («Этап 1 из 2»).
struct DownloadProgressAggregator {
    /// Доли фаз в полосе, в порядке загрузки (см. DownloadPreset.phaseWeights).
    let weights: [Double]
    private(set) var progress = DownloadProgress()
    /// Финальный путь файла из `--print after_move:filepath`.
    private(set) var filePath: String?

    private var finishedPhases = 0

    init(weights: [Double]) {
        self.weights = weights.isEmpty ? [1] : weights
    }

    /// Доля уже скачанных фаз.
    private var completedShare: Double {
        min(1, weights.prefix(finishedPhases).reduce(0, +))
    }

    /// Вес текущей фазы. Фаз бывает меньше ожидаемого (у пресета видео
    /// селектор может взять один общий файл), лишняя фаза веса не имеет.
    private var currentWeight: Double {
        finishedPhases < weights.count ? weights[finishedPhases] : 0
    }

    /// Новая доля полосы. Внутри попытки полоса не откатывается:
    /// `total_bytes_estimate` у фрагментных загрузок скачет. Неизвестная
    /// доля текущей фазы — остаётся то, что уже набрано (или nil).
    private mutating func advance(to share: Double?) {
        progress.fraction = [progress.fraction, share.map { min(1, $0) }]
            .compactMap { $0 }
            .max()
    }

    /// Обрабатывает строку stdout; true — если прогресс изменился.
    mutating func handle(line: String) -> Bool {
        if let snapshot = ProgressParser.parse(line: line) {
            switch snapshot.status {
            case "downloading":
                let done = completedShare
                if let part = ProgressParser.fraction(of: snapshot) {
                    advance(to: done + currentWeight * part)
                } else {
                    advance(to: done > 0 ? done : nil)
                }
                progress.speed = snapshot.speed
                progress.eta = snapshot.eta
                progress.merging = false
                return true
            case "finished":
                finishedPhases += 1
                advance(to: completedShare)
                progress.speed = nil
                progress.eta = nil
                // Все дорожки скачаны — дальше работает ffmpeg.
                if finishedPhases >= weights.count {
                    progress.merging = true
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
