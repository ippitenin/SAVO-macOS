import AppKit
import Combine

/// Ядро приложения — конечный автомат загрузки:
/// idle → fetchingInfo → ready → downloading → done / failed.
/// Любой переход — через transition(to:); счётчик generation
/// инвалидирует устаревшие асинхронные задачи.
@MainActor
final class DownloadController: ObservableObject {
    enum State {
        case idle
        case fetchingInfo
        case ready(VideoInfo)
        case downloading(DownloadProgress)
        case done(filePath: String, info: VideoInfo)
        case failed(SavoError)

        /// Ключ кейса — для анимаций переходов между состояниями.
        var caseKey: String {
            switch self {
            case .idle: return "idle"
            case .fetchingInfo: return "fetching"
            case .ready: return "ready"
            case .downloading: return "downloading"
            case .done: return "done"
            case .failed: return "failed"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var urlText: String = ""

    /// Поколение задач: transition инкрементирует, старые задачи
    /// сверяются и молча умирают.
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    /// Последняя карточка видео — для возврата к выбору качества
    /// после отмены загрузки.
    private var lastInfo: VideoInfo?
    /// Последний увиденный changeCount буфера — защита от повторного автоподхвата.
    private var lastSeenPasteboardCount = NSPasteboard.general.changeCount

    private func transition(to newState: State) {
        generation += 1
        state = newState
    }

    /// Отправка ссылки из поля ввода: валидация и запрос метаданных.
    func submit() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let url = URLValidator.canonicalURL(from: raw) else {
            transition(to: .failed(.invalidURL))
            return
        }
        currentTask?.cancel()
        transition(to: .fetchingInfo)
        let gen = generation
        currentTask = Task { [weak self] in
            // Первый запуск: движок ещё распаковывается — ждём, а не
            // отвечаем «движок не найден».
            await EngineBootstrap.shared.waitUntilInstalled()
            guard EngineInstaller.isInstalled else {
                guard let self, self.generation == gen else { return }
                self.transition(to: .failed(.engineMissing))
                return
            }
            do {
                let info = try await YtDlpClient.fetchInfo(url: url)
                guard let self, self.generation == gen else { return }
                self.lastInfo = info
                self.transition(to: .ready(info))
            } catch is CancellationError {
                // Отменили — состоянием управляет тот, кто отменил.
            } catch let error as SavoError {
                guard let self, self.generation == gen else { return }
                self.transition(to: .failed(error))
            } catch {
                guard let self, self.generation == gen else { return }
                self.transition(to: .failed(.engineFailed(details: String(describing: error))))
            }
        }
    }

    /// Отмена текущей операции и возврат к вводу ссылки.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        transition(to: .idle)
    }

    /// «Скачать ещё» / «Попробовать снова»: сброс к полю ввода.
    func reset(keepURL: Bool = false) {
        currentTask?.cancel()
        currentTask = nil
        if !keepURL {
            urlText = ""
            lastInfo = nil
        }
        transition(to: .idle)
    }

    /// Вставка из буфера по кнопке: подставляет текст и сразу отправляет.
    func pasteAndSubmit() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        submit()
    }

    /// Автоподхват при активации приложения: если включён в настройках,
    /// состояние idle и в буфере новая валидная YouTube-ссылка.
    func handleClipboardOnActivate() {
        guard SettingsStore.shared.autoPasteFromClipboard else { return }
        guard case .idle = state else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastSeenPasteboardCount else { return }
        lastSeenPasteboardCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              URLValidator.canonicalURL(from: text) != nil else { return }
        urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submit()
    }

    /// Запуск скачивания выбранного пресета из состояния ready.
    func download(preset: DownloadPreset) {
        guard case .ready(let info) = state else { return }
        guard EngineInstaller.isInstalled else {
            transition(to: .failed(.engineMissing))
            return
        }
        guard let url = (info.webpageURL.flatMap(URL.init(string:)))
                ?? URLValidator.canonicalURL(from: urlText) else {
            transition(to: .failed(.invalidURL))
            return
        }
        let destination = SettingsStore.shared.downloadsFolder
        currentTask?.cancel()
        transition(to: .downloading(DownloadProgress(
            fraction: nil, speed: nil, eta: nil,
            phase: 1, phaseCount: preset.expectedPhases, merging: false
        )))
        let gen = generation
        currentTask = Task { [weak self] in
            do {
                var finalPath: String?
                for try await update in YtDlpClient.download(
                    url: url, preset: preset, destination: destination
                ) {
                    guard let self, self.generation == gen else { return }
                    switch update {
                    case .progress(let progress):
                        // Прямое обновление без transition: generation
                        // не бампается, задача остаётся валидной.
                        self.state = .downloading(progress)
                    case .finished(let filePath):
                        finalPath = filePath
                    }
                }
                guard let self, self.generation == gen else { return }
                if let finalPath {
                    HistoryStore.shared.add(info: info, preset: preset, filePath: finalPath)
                    self.transition(to: .done(filePath: finalPath, info: info))
                } else {
                    self.transition(to: .failed(.engineFailed(
                        details: L("error.noFileProduced"))))
                }
            } catch is CancellationError {
                // Отменили — состоянием управляет cancelDownload.
            } catch let error as SavoError {
                guard let self, self.generation == gen else { return }
                Self.cleanTempFolder()
                self.transition(to: .failed(error))
            } catch {
                guard let self, self.generation == gen else { return }
                Self.cleanTempFolder()
                self.transition(to: .failed(.engineFailed(details: String(describing: error))))
            }
        }
    }

    /// Отмена активной загрузки: процесс завершается (SIGTERM через
    /// onTermination стрима), временные .part-файлы чистятся,
    /// возврат к выбору качества, если карточка ещё есть.
    func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil
        Self.cleanTempFolder()
        if let lastInfo {
            transition(to: .ready(lastInfo))
        } else {
            transition(to: .idle)
        }
    }

    /// Чистка временной папки загрузок (.part-огрызки yt-dlp).
    private static func cleanTempFolder() {
        let fm = FileManager.default
        let tmp = EnginePaths.tempDownloads
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}

