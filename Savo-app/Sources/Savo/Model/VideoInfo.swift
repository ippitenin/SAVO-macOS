import Foundation

/// Метаданные видео из `yt-dlp -J` (dump-single-json). Декодируется только
/// нужное подмножество полей, всё необязательное — опциональное.
struct VideoInfo: Decodable {
    let id: String
    let title: String
    let channel: String?
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let webpageURL: String?
    let liveStatus: String?
    let formats: [Format]?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, duration, thumbnail, formats
        case webpageURL = "webpage_url"
        case liveStatus = "live_status"
    }

    /// Имя канала для карточки (channel надёжнее, uploader — запасной).
    var channelName: String { channel ?? uploader ?? "" }

    /// Обложка максимального качества.
    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }

    /// Длительность вида «1:23:45» или «12:34».
    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Один формат из списка yt-dlp.
    struct Format: Decodable {
        let formatID: String?
        let ext: String?
        /// Ширина кадра: без неё не определить ступень качества у кадров
        /// не 16:9 (см. PresetBuilder.qualityTier).
        let width: Int?
        let height: Int?
        let fps: Double?
        let vcodec: String?
        let acodec: String?
        let filesize: Double?
        let filesizeApprox: Double?
        let abr: Double?
        let tbr: Double?

        enum CodingKeys: String, CodingKey {
            case ext, width, height, fps, vcodec, acodec, filesize, abr, tbr
            case formatID = "format_id"
            case filesizeApprox = "filesize_approx"
        }

        /// В формате есть видеодорожка.
        var hasVideo: Bool { vcodec != nil && vcodec != "none" }
        /// В формате есть аудиодорожка.
        var hasAudio: Bool { acodec != nil && acodec != "none" }
    }
}
