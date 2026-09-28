import Foundation

/// Одна запись истории скачиваний.
///
/// СОГЛАШЕНИЕ: новые поля — ТОЛЬКО опциональные. Не-опциональное поле
/// делает все старые записи недекодируемыми: история на втором Mac после
/// обновления приложения пропала бы целиком.
struct DownloadRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let channel: String
    let durationText: String?
    let thumbnailURL: String?
    /// Подпись пресета («1080p · MP4», «MP3 · 192 кбит/с»).
    let presetLabel: String
    let filePath: String
    let fileSizeBytes: Int64?
    let date: Date

    /// Файл ещё существует на диске (мог быть удалён/перемещён).
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }
}

/// Итог чтения history.json.
struct HistoryDecodeResult {
    let records: [DownloadRecord]
    /// Сколько записей отброшено как битые.
    let dropped: Int
    /// Файл не разобрался даже как массив — история не прочитана вовсе.
    let unreadable: Bool
}

/// Декодирование истории, терпимое к ошибкам: битая запись отбрасывается
/// поштучно, а не обнуляет всю историю. Чистая логика без UI.
enum HistoryCodec {
    /// Обёртка с непадающим декодированием одного элемента массива.
    private struct Lenient: Decodable {
        let record: DownloadRecord?
        init(from decoder: Decoder) throws {
            record = try? DownloadRecord(from: decoder)
        }
    }

    static func decode(_ data: Data) -> HistoryDecodeResult {
        // Пустой файл — пустая история, не авария.
        guard !data.isEmpty else {
            return HistoryDecodeResult(records: [], dropped: 0, unreadable: false)
        }
        guard let items = try? JSONDecoder().decode([Lenient].self, from: data) else {
            return HistoryDecodeResult(records: [], dropped: 0, unreadable: true)
        }
        let records = items.compactMap(\.record)
        return HistoryDecodeResult(
            records: records,
            dropped: items.count - records.count,
            unreadable: false
        )
    }
}
