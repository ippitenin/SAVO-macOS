import Foundation

/// Журнал движка: командная строка, код выхода и stderr каждого запуска
/// yt-dlp — в `~/Library/Logs/Savo/engine.log`.
///
/// Зачем: yt-dlp при коде 0 пишет предупреждения (SABR, PO Token,
/// урезанный список форматов) только в stderr, UI их не видит, и без
/// журнала причину «скачалось не то» приходится восстанавливать по
/// размеру файла. Запись не должна ломать скачивание: любые ошибки
/// файловой системы молча глотаются.
enum EngineLog {
    /// Папка по умолчанию — стандартное место логов macOS, видна в Console.app.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Savo", isDirectory: true)
    }
    static let fileName = "engine.log"
    /// Больше строк на один запуск не пишем: хвост обрезается с пометкой.
    static let maxLinesPerRun = 200
    /// При таком размере файл уезжает в `engine.log.1` (старый .1 затирается).
    static let rotateAtBytes = 2 * 1024 * 1024

    /// Одна очередь на все записи: блоки разных запусков не перемешиваются.
    private static let queue = DispatchQueue(label: "com.pitenin.savo.engine-log", qos: .utility)

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Полный путь журнала по умолчанию.
    static var fileURL: URL { defaultDirectory.appendingPathComponent(fileName) }

    /// Дописывает блок одного запуска. `duration` — время работы процесса
    /// (постоянные данные о скорости старта движка).
    /// `directory` переопределяется только в харнессе.
    static func record(
        arguments: [String],
        stderr: [String],
        code: Int32,
        duration: TimeInterval? = nil,
        directory: URL = defaultDirectory
    ) {
        let took = duration.map { String(format: " %.2fs", $0) } ?? ""
        var lines = [
            "=== \(stampFormatter.string(from: Date())) exit=\(code)\(took)",
            "$ yt-dlp " + arguments.joined(separator: " ")
        ]
        lines += stderr.prefix(maxLinesPerRun)
        if stderr.count > maxLinesPerRun {
            lines.append("… ещё \(stderr.count - maxLinesPerRun) строк опущено")
        }
        let block = lines.joined(separator: "\n") + "\n\n"
        queue.sync { append(block, in: directory) }
    }

    /// Секунды с момента `start` по монотонным часам (перевод системного
    /// времени не искажает замер).
    static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let d = start.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Служебное событие Savo (установка/обновление движка, история).
    static func event(_ message: String, directory: URL = defaultDirectory) {
        let block = "=== \(stampFormatter.string(from: Date())) [savo] \(message)\n\n"
        queue.sync { append(block, in: directory) }
    }

    /// Последние `lines` строк журнала — для отчёта об отладке.
    static func tail(lines: Int, directory: URL = defaultDirectory) -> String {
        let url = directory.appendingPathComponent(fileName)
        guard let data = queue.sync(execute: { try? Data(contentsOf: url) }),
              let text = String(data: data, encoding: .utf8) else { return "" }
        var all = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        // Блоки разделены пустой строкой — хвост из пустых строк не считаем.
        while all.last == "" { all.removeLast() }
        return all.suffix(lines).joined(separator: "\n")
    }

    private static func append(_ text: String, in directory: URL) {
        let fm = FileManager.default
        let fileURL = directory.appendingPathComponent(fileName)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded(fileURL)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static func rotateIfNeeded(_ fileURL: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int),
              size > rotateAtBytes else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: fileURL, to: rotated)
    }
}
