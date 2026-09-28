import Foundation

/// Событие работающего процесса: строка одного из потоков вывода.
enum ProcessEvent {
    case stdout(String)
    case stderr(String)
}

/// Ненулевой код выхода процесса.
struct ProcessExitError: Error {
    let code: Int32
}

/// Процесс не уложился в отведённое время и был завершён.
struct ProcessTimeoutError: Error {}

/// Асинхронные обёртки над Foundation Process. Единственная точка запуска
/// внешних бинарников (yt-dlp, ffmpeg, ditto) во всём приложении.
///
/// ВАЖНО: чтение пайпов — блокирующие read()-вызовы, поэтому оно строго
/// на GCD-потоках. FileHandle.bytes и Task.detached исполняются на
/// кооперативном пуле Swift Concurrency, и блокирующий read там намертво
/// останавливает весь async-код приложения (потоков в пуле не больше,
/// чем ядер, и пара заблокированных уже заметна).
enum ProcessRunner {
    /// Одна последовательная очередь на все завершения: два параллельных
    /// terminateTree (onCancel + catch) не должны толкаться локтями.
    private static let terminationQueue = DispatchQueue(
        label: "com.pitenin.savo.process-termination", qos: .userInitiated
    )

    /// Переводит только что запущенный процесс в СОБСТВЕННУЮ группу.
    /// Групповой kill(-pid) — единственный надёжный способ накрыть всё
    /// потомство разом: yt-dlp порождает ffmpeg (а старая onefile-сборка
    /// ещё и рабочий процесс бутлоадера PyInstaller), и гонка форка в
    /// момент сигнала оставляет сирот, которых обход дерева по ppid уже
    /// не находит.
    static func isolateProcessGroup(_ process: Process) {
        let pid = process.processIdentifier
        _ = setpgid(pid, pid)
    }

    /// Асинхронно завершает процесс вместе со всей его группой.
    /// Через 2 секунды выжившие добиваются SIGKILL — его игнорировать
    /// нельзя (пауза даёт yt-dlp прибрать .part-файлы).
    static func terminateTree(_ process: Process) {
        terminationQueue.async {
            guard process.isRunning else { return }
            let root = process.processIdentifier
            let tree = [root] + descendants(of: root)
            // Вся группа одним сигналом (включая сирот)…
            kill(-root, SIGTERM)
            // …и обход дерева как страховка, если кто-то сменил группу.
            for pid in tree.reversed() {
                kill(pid, SIGTERM)
            }
            terminationQueue.asyncAfter(deadline: .now() + 2) {
                kill(-root, SIGKILL)
                for pid in ([root] + descendants(of: root)).reversed()
                where kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// Все потомки процесса (рекурсивно) по снимку таблицы процессов.
    private static func descendants(of root: Int32) -> [Int32] {
        // Снимок из ядра (sysctl) — без порождения вспомогательных
        // процессов: Foundation Process при одновременном спавне из
        // двух потоков склонен к дедлоку.
        let snapshot = allProcesses()
        var result: [Int32] = []
        var queue: [Int32] = [root]
        while let pid = queue.popLast() {
            let kids = snapshot.filter { $0.ppid == pid }.map(\.pid)
            result.append(contentsOf: kids)
            queue.append(contentsOf: kids)
        }
        return result
    }

    /// Все процессы системы с родителями (KERN_PROC_ALL).
    private static func allProcesses() -> [(pid: Int32, ppid: Int32)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actual).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    /// Запуск с полным сбором вывода (метаданные `-J`: stdout — один
    /// многомегабайтный JSON). Отмена задачи завершает дерево процессов.
    static func runCollecting(
        _ executable: URL,
        arguments: [String]
    ) async throws -> (stdout: Data, stderr: String, code: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class OutputBox: @unchecked Sendable {
            // Каждое поле пишет ровно один GCD-таск до group.leave,
            // читается после group.notify — синхронизацию даёт DispatchGroup.
            var stdout = Data()
            var stderr = Data()
        }
        let box = OutputBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.notify(queue: .global(qos: .utility)) {
                        continuation.resume(returning: (
                            box.stdout,
                            String(data: box.stderr, encoding: .utf8) ?? "",
                            proc.terminationStatus
                        ))
                    }
                }
                do {
                    try process.run()
                    isolateProcessGroup(process)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            terminateTree(process)
        }
    }

    /// То же с пределом времени: не уложился — дерево процессов
    /// завершается, бросается ProcessTimeoutError. Для служебных запусков
    /// (распаковка, проверочный `--version`), где зависание недопустимо.
    static func runCollecting(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> (stdout: Data, stderr: String, code: Int32) {
        try await withThrowingTaskGroup(
            of: (stdout: Data, stderr: String, code: Int32).self
        ) { group in
            group.addTask { try await runCollecting(executable, arguments: arguments) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessTimeoutError()
            }
            // Отмена проигравшей задачи: процесс завершится через onCancel,
            // таймер — просто проснётся с CancellationError.
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ProcessTimeoutError() }
            return result
        }
    }

    /// Стрим процесса: события + явная ручка завершения дерева.
    /// НЕ полагаемся на отмену задач: next() у AsyncThrowingStream при
    /// отменённой задаче тихо возвращает nil, не вызывая onTermination, —
    /// владелец обязан дёрнуть terminate() сам.
    struct ProcessStream {
        let events: AsyncThrowingStream<ProcessEvent, Error>
        let terminate: @Sendable () -> Void
    }

    /// Запуск со стримом строк обоих потоков (скачивание с прогрессом).
    /// Стрим завершается при коде 0, иначе бросает ProcessExitError.
    /// Обрыв потребителя тоже завершает дерево (onTermination), но
    /// надёжный путь отмены — явный вызов terminate().
    static func stream(
        _ executable: URL,
        arguments: [String]
    ) -> ProcessStream {
        var terminateHandle: (@Sendable () -> Void)!
        let events = AsyncThrowingStream<ProcessEvent, Error> { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let group = DispatchGroup()

            // Построчный читатель пайпа на GCD-потоке до EOF.
            func startReader(
                _ handle: FileHandle,
                _ wrap: @escaping @Sendable (String) -> ProcessEvent
            ) {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    var buffer = Data()
                    let newline = Data([0x0A])
                    func emit(_ data: Data) {
                        guard let line = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .init(charactersIn: "\r")),
                              !line.isEmpty else { return }
                        continuation.yield(wrap(line))
                    }
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }   // EOF
                        buffer.append(chunk)
                        while let range = buffer.range(of: newline) {
                            emit(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        }
                    }
                    emit(buffer)   // хвост без перевода строки
                    group.leave()
                }
            }
            startReader(outPipe.fileHandleForReading) { .stdout($0) }
            startReader(errPipe.fileHandleForReading) { .stderr($0) }

            process.terminationHandler = { proc in
                // Дочитываем хвосты пайпов до EOF, затем закрываем стрим.
                group.notify(queue: .global(qos: .utility)) {
                    if proc.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ProcessExitError(code: proc.terminationStatus))
                    }
                }
            }
            // Безусловно: при нормальном finish() процесс уже мёртв и
            // terminateTree — no-op; при любом другом завершении стрима
            // (обрыв итератора) дерево должно умереть.
            continuation.onTermination = { _ in
                terminateTree(process)
            }
            terminateHandle = {
                terminateTree(process)
            }
            do {
                try process.run()
                isolateProcessGroup(process)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return ProcessStream(events: events, terminate: terminateHandle)
    }
}
