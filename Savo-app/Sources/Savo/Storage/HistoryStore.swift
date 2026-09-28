import Foundation

/// История скачиваний: history.json в Application Support, максимум 100 записей.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 100

    @Published private(set) var records: [DownloadRecord] = []

    private let fileURL: URL

    private convenience init() {
        let dir = EnginePaths.appSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("history.json"))
    }

    /// Хранилище поверх произвольного файла — для харнесса.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Добавляет запись о скачанном файле.
    func add(info: VideoInfo, preset: DownloadPreset, filePath: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64)
            .flatMap { $0 }
        let record = DownloadRecord(
            id: UUID(),
            title: info.title,
            channel: info.channelName,
            durationText: info.durationText,
            thumbnailURL: info.thumbnail,
            presetLabel: preset.label,
            filePath: filePath,
            fileSizeBytes: size,
            date: Date()
        )
        records.insert(record, at: 0)
        if records.count > Self.limit {
            records.removeLast(records.count - Self.limit)
        }
        save()
    }

    func delete(_ record: DownloadRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    /// Читает историю, отбрасывая битые записи. Если что-то отброшено или
    /// файл не разобрался — исходные байты уходят в history.json.bak ДО
    /// первого save(): иначе следующая же запись затёрла бы историю навсегда.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let result = HistoryCodec.decode(data)
        records = result.records
        guard result.unreadable || result.dropped > 0 else { return }
        let backup = fileURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? data.write(to: backup, options: .atomic)
        EngineLog.event(result.unreadable
            ? "history.json не разобран, копия — \(backup.lastPathComponent)"
            : "history.json: отброшено битых записей — \(result.dropped), копия — \(backup.lastPathComponent)")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
