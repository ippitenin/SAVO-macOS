import Foundation

/// Версия yt-dlp («2026.08.19», у внеочередных сборок — «2026.08.19.1»).
/// Сравнение покомпонентно по числам: «2026.8.19» == «2026.08.19»,
/// «2026.08.19.1» > «2026.08.19». Строковое сравнение ошиблось бы
/// на ведущих нулях.
struct EngineVersion: Comparable, CustomStringConvertible {
    let components: [Int]
    /// Исходная строка (для файлов VERSION и сообщений).
    let description: String

    init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...6).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII),
                  let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        components = numbers
        description = text
    }

    /// Компоненты, дополненные нулями до общей длины.
    private static func padded(_ a: EngineVersion, _ b: EngineVersion) -> ([Int], [Int]) {
        let n = max(a.components.count, b.components.count)
        return (a.components + Array(repeating: 0, count: n - a.components.count),
                b.components + Array(repeating: 0, count: n - b.components.count))
    }

    static func < (a: EngineVersion, b: EngineVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x.lexicographicallyPrecedes(y)
    }

    static func == (a: EngineVersion, b: EngineVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x == y
    }
}
