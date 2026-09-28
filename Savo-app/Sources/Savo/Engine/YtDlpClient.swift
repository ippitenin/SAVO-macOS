import Foundation

/// Клиент yt-dlp: получение метаданных и (следующим этапом) скачивание.
/// Запускает рабочую копию движка из Application Support.
enum YtDlpClient {
    /// Общие аргументы каждого вызова: без плейлистов, с вложенным
    /// JS-рантаймом (без deno YouTube-экстрактор теряет форматы).
    /// Таймаут сокета и повторы: зависшее соединение YouTube иначе
    /// молча стоит вечно — yt-dlp сам переподключится и продолжит.
    /// `--ignore-config`: чужой ~/.config/yt-dlp/config не влияет на Savo.
    /// `--ffmpeg-location` нужен и при `-J`: без ffmpeg yt-dlp предупреждает
    /// «ffmpeg not found» и может иначе выбирать форматы.
    static var baseArguments: [String] {
        [
            "--ignore-config",
            "--no-playlist",
            "--js-runtimes", "deno:\(EnginePaths.workDeno.path)",
            "--ffmpeg-location", EnginePaths.workBin.path,
            "--socket-timeout", "30",
            "--retries", "10",
            "--fragment-retries", "10"
        ]
    }

    /// Полные аргументы одной попытки скачивания. Чистая функция —
    /// проверяется харнессом без запуска движка.
    static func downloadArguments(
        preset: DownloadPreset,
        destination: URL,
        attempt: [String],
        url: URL
    ) -> [String] {
        // --print подразумевает --simulate и --quiet, поэтому явные
        // --no-simulate и --progress обязательны.
        preset.formatArguments + baseArguments + attempt + [
            "--newline",
            "--progress",
            // «download:» — селектор типа, «savo:» — наш префикс
            // в выводе (см. ProgressParser.linePrefix).
            "--progress-template", "download:savo:%(progress)j",
            "-P", destination.path,
            "-P", "temp:\(EnginePaths.tempDownloads.path)",
            "-o", preset.outputTemplate,
            "--no-mtime",
            "--no-simulate",
            "--print", "after_move:filepath",
            url.absoluteString
        ]
    }

    /// Попытки по очереди: набор клиентов YouTube-экстрактора.
    /// YouTube всё шире требует GVS PO Token, и клиенты по умолчанию
    /// периодически отвечают 403 либо «подтвердите, что вы не робот»
    /// (метаданные при этом извлекаются — падает только скачивание).
    /// web_embedded в этих случаях обычно продолжает отдавать рабочие
    /// ссылки. Гарантии полного набора качеств у запасного пути НЕТ:
    /// web-клиентам YouTube временами отдаёт один itag 18 (360p).
    /// Подмену качества исключает строгий селектор пресета
    /// (DownloadPreset.formatArguments): нет обещанной высоты — yt-dlp
    /// падает с formatUnavailable, и цикл идёт к следующему клиенту.
    ///
    /// Первый вариант пустой: обычный путь остаётся основным.
    /// Правила YouTube меняются — это единственное место для правки.
    static let clientAttempts: [[String]] = [
        [],
        ["--extractor-args", "youtube:player_client=web_embedded"]
    ]

    /// Отказ, который лечится сменой клиента. formatUnavailable — список
    /// форматов у текущего клиента урезан, другой может отдать полный.
    /// Сознательно НЕ включает tooManyRequests: повтор при лимите
    /// частоты только усугубляет его.
    static func isRetriable(_ error: SavoError) -> Bool {
        switch error {
        case .forbidden, .botCheck, .formatUnavailable: return true
        default: return false
        }
    }

    /// Метаданные видео: `yt-dlp -J --no-playlist <url>`.
    static func fetchInfo(url: URL) async throws -> VideoInfo {
        // Аренда движка на всю цепочку попыток: обновление не подменит
        // каталог между ними.
        try await EngineGate.shared.withLease {
            try await fetchInfoLeased(url: url)
        }
    }

    private static func fetchInfoLeased(url: URL) async throws -> VideoInfo {
        let ytDlp = EnginePaths.workYtDlp
        guard FileManager.default.isExecutableFile(atPath: ytDlp.path) else {
            throw SavoError.engineMissing
        }
        // Отказ YouTube — повод сменить клиент, а не сдаться: перебираем
        // варианты, пока не получим метаданные.
        var lastError = SavoError.badMetadata
        for attempt in clientAttempts {
            try Task.checkCancellation()
            let arguments = ["-J"] + baseArguments + attempt + [url.absoluteString]
            let started = ContinuousClock.now
            let result = try await ProcessRunner.runCollecting(ytDlp, arguments: arguments)
            try Task.checkCancellation()
            EngineLog.record(
                arguments: arguments,
                stderr: result.stderr.components(separatedBy: "\n").filter { !$0.isEmpty },
                code: result.code,
                duration: EngineLog.seconds(since: started)
            )
            guard result.code == 0 else {
                let error = SavoError.map(stderr: result.stderr)
                guard isRetriable(error) else { throw error }
                lastError = error
                continue
            }
            do {
                return try JSONDecoder().decode(VideoInfo.self, from: result.stdout)
            } catch {
                throw SavoError.badMetadata
            }
        }
        // Варианты кончились — отдаём отказ последней попытки.
        throw lastError
    }

    /// Событие скачивания для контроллера.
    enum DownloadUpdate {
        case progress(DownloadProgress)
        case finished(filePath: String)
    }

    /// Исход одной попытки скачивания.
    private enum AttemptOutcome {
        /// Стрим уже закрыт: успех, отмена или окончательная ошибка.
        case done
        /// YouTube отказал — имеет смысл следующий клиент из цепочки.
        case retry
    }

    /// Скачивание пресета в папку назначения. Стрим прогресса; при
    /// успехе последнее событие — финальный путь файла. Отмена
    /// потребителя завершает процесс.
    static func download(
        url: URL,
        preset: DownloadPreset,
        destination: URL
    ) -> AsyncThrowingStream<DownloadUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Аренда движка до конца всех попыток (см. EngineGate).
                EngineGate.shared.acquire()
                defer { EngineGate.shared.release() }
                let ytDlp = EnginePaths.workYtDlp
                guard FileManager.default.isExecutableFile(atPath: ytDlp.path) else {
                    continuation.finish(throwing: SavoError.engineMissing)
                    return
                }
                // Попытки по очереди: отказ YouTube лечится сменой клиента.
                // Прогресс каждой попытки считается заново, поэтому
                // агрегатор создаётся внутри цикла.
                for (index, attempt) in clientAttempts.enumerated() {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let isLastAttempt = index == clientAttempts.count - 1
                    let arguments = downloadArguments(
                        preset: preset, destination: destination,
                        attempt: attempt, url: url
                    )
                    var aggregator = DownloadProgressAggregator(phaseCount: preset.expectedPhases)
                    var stderrTail: [String] = []
                    var stderrAll: [String] = []
                    let started = ContinuousClock.now
                    let procStream = ProcessRunner.stream(ytDlp, arguments: arguments)
                    // Отмена потребителя обязана убить дерево процессов явно:
                    // на отмену задач стрим полагаться нельзя (см. ProcessStream).
                    let outcome: AttemptOutcome = await withTaskCancellationHandler {
                    do {
                        for try await event in procStream.events {
                            try Task.checkCancellation()
                            switch event {
                            case .stdout(let line):
                                if aggregator.handle(line: line) {
                                    continuation.yield(.progress(aggregator.progress))
                                }
                            case .stderr(let line):
                                stderrAll.append(line)
                                stderrTail.append(line)
                                if stderrTail.count > 40 { stderrTail.removeFirst() }
                            }
                        }
                        EngineLog.record(arguments: arguments, stderr: stderrAll, code: 0,
                                         duration: EngineLog.seconds(since: started))
                        // Код 0: финальный путь обязан быть напечатан after_move.
                        if let path = aggregator.filePath,
                           FileManager.default.fileExists(atPath: path) {
                            continuation.yield(.finished(filePath: path))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: SavoError.engineFailed(
                                details: L("error.noFileProduced")))
                        }
                        return .done
                    } catch is CancellationError {
                        procStream.terminate()
                        continuation.finish(throwing: CancellationError())
                        return .done
                    } catch let exit as ProcessExitError {
                        EngineLog.record(arguments: arguments, stderr: stderrAll, code: exit.code,
                                         duration: EngineLog.seconds(since: started))
                        let error = SavoError.map(stderr: stderrTail.joined(separator: "\n"))
                        // Отказ, который лечится сменой клиента, — ещё не финал.
                        if isRetriable(error), !isLastAttempt {
                            return .retry
                        }
                        continuation.finish(throwing: error)
                        return .done
                    } catch {
                        procStream.terminate()
                        continuation.finish(throwing: error)
                        return .done
                    }
                    } onCancel: {
                        procStream.terminate()
                    }
                    if case .done = outcome { return }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

}

extension DownloadPreset {
    /// Число фаз скачивания для прогресса «Этап N из M».
    var expectedPhases: Int {
        if case .video = kind { return 2 }
        return 1
    }
}
