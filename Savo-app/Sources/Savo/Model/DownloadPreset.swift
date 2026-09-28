import Foundation

/// Пресет скачивания: понятный пользователю вариант качества,
/// разворачивающийся в аргументы yt-dlp. Чистая логика без UI.
struct DownloadPreset: Equatable, Identifiable, Hashable {
    /// Тип пресета.
    enum Kind: Equatable, Hashable {
        /// Видео со звуком до указанной высоты (merge в MP4).
        case video(height: Int)
        /// Только аудио: m4a-оригинал или mp3 с битрейтом (кбит/с).
        case audioM4A
        case audioMP3(bitrate: Int)
        /// Только видеодорожка без звука (MP4).
        case videoOnly(height: Int)
    }

    let kind: Kind
    /// Примерный размер файла в байтах (nil — неизвестен).
    let estimatedBytes: Double?
    /// На этой высоте у ролика есть дорожка H.264 (avc1), то есть файл
    /// откроется двойным кликом в QuickTime. Для аудио вопрос не стоит,
    /// поэтому по умолчанию true.
    var quickTimeReady: Bool = true
    /// Ступень качества для подписи в терминах YouTube («1080p»). В kind —
    /// фактическая высота кадра для селектора yt-dlp: у кадра 2:1 ступени
    /// 1080p соответствует высота 960. nil — ступень равна высоте.
    var tier: Int? = nil

    /// Ступень качества видео-варианта (nil — аудио).
    var qualityTier: Int? {
        switch kind {
        case .video(let h), .videoOnly(let h): return tier ?? h
        case .audioM4A, .audioMP3: return nil
        }
    }

    var id: String {
        switch kind {
        case .video(let h): return "video\(h)"
        case .audioM4A: return "audioM4A"
        case .audioMP3(let b): return "mp3\(b)"
        case .videoOnly(let h): return "muted\(h)"
        }
    }

    /// Аргументы выбора формата для yt-dlp.
    /// ≤1080p приоритет avc1+m4a — такой MP4 гарантированно открывается
    /// в QuickTime; выше 1080p avc1 обычно нет (vp9/av1).
    ///
    /// ВАЖНО: высота требуется точная (`height=`), а не «не выше»
    /// (`height<=`). Ступени берутся из реальных форматов ролика, так что
    /// обещанная высота у него есть. Но скачивание — отдельный запрос к
    /// YouTube, и запасному клиенту он может отдать урезанный список
    /// (SABR / PO Token): с `height<=` последний вариант `b[height<=H]`
    /// тихо скачивал itag 18 (360p) под подписью «1080p». Со строгой
    /// высотой yt-dlp падает с «Requested format is not available» —
    /// это SavoError.formatUnavailable: приложение пробует другой клиент
    /// либо честно сообщает об отказе.
    var formatArguments: [String] {
        switch kind {
        case .video(let h):
            return [
                "-f",
                "bv*[height=\(h)][vcodec^=avc1]+ba[ext=m4a]/bv*[height=\(h)]+ba/b[height=\(h)]",
                "--merge-output-format", "mp4"
            ]
        case .audioM4A:
            return ["-f", "ba[ext=m4a]/ba", "-x", "--audio-format", "m4a"]
        case .audioMP3(let bitrate):
            return ["-x", "--audio-format", "mp3", "--audio-quality", "\(bitrate)K"]
        case .videoOnly(let h):
            return [
                "-f", "bv*[height=\(h)][vcodec^=avc1]/bv*[height=\(h)]",
                "--remux-video", "mp4"
            ]
        }
    }

    /// Предел длины названия в имени файла, в БАЙТАХ (кириллица — 2 байта
    /// на символ). yt-dlp обрезает до санитизации, а та раздувает символы
    /// («|» → «｜», 1 → 3 байта); плюс метка и временные суффиксы
    /// (.f137.mp4.part) — 150 оставляет запас до лимита APFS в 255 байт.
    static let maxTitleBytes = 150

    /// Метка варианта в имени файла: разные качества одного ролика не
    /// должны давать одно имя — иначе yt-dlp сочтёт файл «уже скачанным»
    /// и молча вернёт прежний (720p после 1080p, MP3 другого битрейта).
    var fileTag: String {
        switch kind {
        case .video(let h): return L("preset.tag.video", tier ?? h)
        case .videoOnly(let h): return L("preset.tag.muted", tier ?? h)
        case .audioM4A: return L("preset.tag.m4a")
        case .audioMP3(let b): return L("preset.tag.mp3", b)
        }
    }

    /// Шаблон имени файла (`-o`): «Название [28.09.2026, 1080p].mp4».
    /// Дата публикации различает одноимённые эфиры; конструкция
    /// `&{}, |` печатает «дата, » только если дата известна — без неё
    /// получится «[1080p]», без висячей запятой.
    var outputTemplate: String {
        "%(title).\(Self.maxTitleBytes)B "
            + "[%(upload_date>%d.%m.%Y&{}, |)s\(Self.templateSafe(fileTag))].%(ext)s"
    }

    /// Литерал для шаблона yt-dlp: «%» — управляющий символ шаблона,
    /// «/» создал бы подпапку, «:» Finder показывает как «/».
    static func templateSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " ")
    }

    /// Название варианта в списке.
    var label: String {
        switch kind {
        case .video(let h), .videoOnly(let h): return "\(tier ?? h)p · MP4"
        case .audioM4A: return L("preset.m4a")
        case .audioMP3(let b): return L("preset.mp3", b)
        }
    }

    /// Предупреждение о совместимости с QuickTime. Смотрим на реальный
    /// кодек, а не на высоту: 1440p в avc1 откроется, а 1080p в одном
    /// лишь VP9 — нет.
    var warning: String? {
        switch kind {
        case .video, .videoOnly:
            return quickTimeReady ? nil : L("preset.compatWarning")
        case .audioM4A, .audioMP3:
            return nil
        }
    }

    /// Примерный размер «≈ 450 МБ» или «размер неизвестен».
    var sizeText: String {
        guard let bytes = estimatedBytes, bytes > 0 else { return L("preset.sizeUnknown") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return L("preset.sizeApprox", formatter.string(fromByteCount: Int64(bytes)))
    }
}

/// Построение доступных пресетов по метаданным видео.
enum PresetBuilder {
    /// Варианты битрейта MP3 (кбит/с).
    static let mp3Bitrates = [320, 192, 128]

    /// Ниже этой ступени варианты не показываем: качать эфир в 144p
    /// незачем, а список из-за них разрастается.
    private static let minMeaningfulTier = 360

    /// Стандартные ступени YouTube: рамка 16:9 (длинная × короткая сторона).
    private static let tierFrames: [(tier: Int, long: Int, short: Int)] = [
        (144, 256, 144), (240, 426, 240), (360, 640, 360), (480, 854, 480),
        (720, 1280, 720), (1080, 1920, 1080), (1440, 2560, 1440),
        (2160, 3840, 2160), (4320, 7680, 4320)
    ]
    /// Допуск на кодирование нестандартными размерами (1920×1088, 428×240).
    private static let tierTolerance = 8

    /// Ступень качества в терминах YouTube: наименьшая стандартная рамка
    /// 16:9, в которую кадр помещается в любой ориентации. Высоту в
    /// пикселях показывать нельзя: кадр 2:1 3840×1920 YouTube называет
    /// «2160p», 854×428 — «480p», вертикальный 1080×1920 — «1080p».
    /// Без ширины — по высоте (как для 16:9).
    static func qualityTier(width: Int?, height: Int?) -> Int? {
        guard let height else { return nil }
        guard let width else { return height }
        let long = max(width, height), short = min(width, height)
        for frame in tierFrames
        where long <= frame.long + tierTolerance && short <= frame.short + tierTolerance {
            return frame.tier
        }
        return short
    }

    /// Вариант качества: ступень для подписи и фактическая высота кадра
    /// для селектора.
    struct VideoQuality: Equatable {
        let tier: Int
        let height: Int
    }

    /// Реально доступные ступени ролика, по убыванию.
    ///
    /// ВАЖНО: берутся из форматов ролика, а не из фиксированной лестницы.
    /// Лестница обещала ступени, которых у ролика нет (для видео с 1080p
    /// и 360p показывались ещё 720p и 480p), и выбор такой ступени тихо
    /// скачивал ближайшее меньшее качество.
    static func videoQualities(for info: VideoInfo) -> [VideoQuality] {
        var heightsByTier: [Int: Set<Int>] = [:]
        for format in info.formats ?? [] where format.hasVideo {
            guard let height = format.height,
                  let tier = qualityTier(width: format.width, height: height) else { continue }
            heightsByTier[tier, default: []].insert(height)
        }
        let qualities = heightsByTier.map { tier, heights in
            // Обычно у ступени одна высота; если несколько — та, где есть
            // H.264 (откроется в QuickTime), иначе наибольшая.
            let sorted = heights.sorted(by: >)
            let height = sorted.first { hasAVC(height: $0, info: info) } ?? sorted[0]
            return VideoQuality(tier: tier, height: height)
        }.sorted { $0.tier > $1.tier }
        let meaningful = qualities.filter { $0.tier >= minMeaningfulTier }
        // Ролик целиком ниже порога — показываем его максимум, чтобы
        // список никогда не оказался пустым.
        return meaningful.isEmpty ? Array(qualities.prefix(1)) : meaningful
    }

    /// Есть ли на этой высоте дорожка H.264 (avc1): только такой MP4
    /// открывается в QuickTime без сторонних плееров.
    static func hasAVC(height: Int, info: VideoInfo) -> Bool {
        (info.formats ?? []).contains {
            $0.hasVideo && $0.height == height && ($0.vcodec ?? "").hasPrefix("avc1")
        }
    }

    /// Вариант по умолчанию: самый высокий из открывающихся в QuickTime.
    /// 4K на YouTube почти всегда VP9/AV1, поэтому «просто максимум» дал
    /// бы файл, который не проигрывается двойным кликом. Если совместимых
    /// нет вовсе — берём максимум (список уже отсортирован по убыванию).
    static func defaultPreset(from presets: [DownloadPreset]) -> DownloadPreset? {
        presets.first { $0.quickTimeReady } ?? presets.first
    }

    /// Пресеты вкладки «Видео».
    static func videoPresets(for info: VideoInfo) -> [DownloadPreset] {
        videoQualities(for: info).map {
            DownloadPreset(kind: .video(height: $0.height),
                           estimatedBytes: estimateVideo(height: $0.height, info: info, withAudio: true),
                           quickTimeReady: hasAVC(height: $0.height, info: info),
                           tier: $0.tier)
        }
    }

    /// Пресеты вкладки «Аудио».
    static func audioPresets(for info: VideoInfo) -> [DownloadPreset] {
        var presets = [DownloadPreset(kind: .audioM4A, estimatedBytes: estimateBestAudio(info: info))]
        for bitrate in mp3Bitrates {
            let bytes = info.duration.map { Double(bitrate) * $0 * 125 }
            presets.append(DownloadPreset(kind: .audioMP3(bitrate: bitrate), estimatedBytes: bytes))
        }
        return presets
    }

    /// Пресеты вкладки «Без звука».
    static func videoOnlyPresets(for info: VideoInfo) -> [DownloadPreset] {
        videoQualities(for: info).map {
            DownloadPreset(kind: .videoOnly(height: $0.height),
                           estimatedBytes: estimateVideo(height: $0.height, info: info, withAudio: false),
                           quickTimeReady: hasAVC(height: $0.height, info: info),
                           tier: $0.tier)
        }
    }

    /// Оценка размера видео: формат-кандидат (видеодорожка ≤ height,
    /// предпочтение avc1, максимальный tbr) + лучший m4a при withAudio.
    private static func estimateVideo(height: Int, info: VideoInfo, withAudio: Bool) -> Double? {
        let formats = info.formats ?? []
        let candidates = formats.filter { $0.hasVideo && ($0.height ?? 0) <= height && $0.height != nil }
        guard let bestHeight = candidates.compactMap(\.height).max() else { return nil }
        let atHeight = candidates.filter { $0.height == bestHeight }
        let preferred = atHeight.filter { ($0.vcodec ?? "").hasPrefix("avc1") }
        let pick = (preferred.isEmpty ? atHeight : preferred)
            .max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
        guard let pick else { return nil }
        var total = size(of: pick, duration: info.duration)
        if withAudio, let audio = estimateBestAudio(info: info) {
            total = (total ?? 0) + audio
        }
        return total
    }

    /// Оценка размера лучшей аудиодорожки (предпочтение m4a).
    private static func estimateBestAudio(info: VideoInfo) -> Double? {
        let audios = (info.formats ?? []).filter { $0.hasAudio && !$0.hasVideo }
        guard !audios.isEmpty else { return nil }
        let m4a = audios.filter { $0.ext == "m4a" }
        let pick = (m4a.isEmpty ? audios : m4a)
            .max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }
        guard let pick else { return nil }
        return size(of: pick, duration: info.duration)
    }

    /// Размер формата: точный, приблизительный или битрейт × длительность.
    private static func size(of format: VideoInfo.Format, duration: Double?) -> Double? {
        if let s = format.filesize { return s }
        if let s = format.filesizeApprox { return s }
        if let tbr = format.tbr, let duration { return tbr * duration * 125 }
        return nil
    }
}
