import Foundation

/// Аренда рабочей копии yt-dlp. onedir-сборка лениво читает модули из
/// _internal по пути, поэтому подмена каталога под живым процессом его
/// уронит. Каждый запуск движка держит аренду; подмена выполняется только
/// когда аренд нет, под тем же замком — новый запуск её дождётся.
final class EngineGate: @unchecked Sendable {
    static let shared = EngineGate()

    // Все поля — только под lock.
    private let lock = NSLock()
    private var leases = 0
    private var idleHandler: (@Sendable () -> Void)?

    /// Обработчик «аренд больше нет» (применить отложенное обновление).
    /// Вызывается вне замка, на потоке освободившего аренду.
    func setOnIdle(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        idleHandler = handler
        lock.unlock()
    }

    func acquire() {
        lock.lock()
        leases += 1
        lock.unlock()
    }

    func release() {
        lock.lock()
        leases -= 1
        let handler = leases == 0 ? idleHandler : nil
        lock.unlock()
        handler?()
    }

    /// Выполняет `body`, удерживая аренду.
    func withLease<T>(_ body: () async throws -> T) async rethrows -> T {
        acquire()
        defer { release() }
        return try await body()
    }

    /// Выполняет `body` под замком, только если аренд нет. `body` должен
    /// быть мгновенным (rename), иначе новые запуски будут ждать.
    /// true — выполнено.
    @discardableResult
    func performIfIdle(_ body: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard leases == 0 else { return false }
        try body()
        return true
    }
}
