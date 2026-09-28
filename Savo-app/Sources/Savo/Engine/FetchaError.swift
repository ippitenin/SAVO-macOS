import Foundation

/// Человекочитаемые ошибки Savo. Технический stderr движка сворачивается
/// в понятные русские сообщения; сырой хвост доступен в details.
enum SavoError: Error {
    case invalidURL
    case engineMissing
    case videoUnavailable
    case privateVideo
    case forbidden
    case botCheck
    case tooManyRequests
    case network
    case unsupportedURL
    case liveNotFinished
    case badMetadata
    /// Выбранного качества сейчас нет у клиента, которым идёт скачивание
    /// (урезанный список форматов). Лечится сменой клиента или паузой.
    case formatUnavailable
    case engineFailed(details: String)

    /// Сообщение для пользователя.
    var message: String {
        switch self {
        case .invalidURL: return L("error.invalidURL")
        case .engineMissing: return L("error.engineMissing")
        case .videoUnavailable: return L("error.videoUnavailable")
        case .privateVideo: return L("error.privateVideo")
        case .forbidden: return L("error.forbidden")
        case .botCheck: return L("error.botCheck")
        case .tooManyRequests: return L("error.tooManyRequests")
        case .network: return L("error.network")
        case .unsupportedURL: return L("error.unsupportedURL")
        case .liveNotFinished: return L("error.liveNotFinished")
        case .badMetadata: return L("error.badMetadata")
        case .formatUnavailable: return L("error.formatUnavailable")
        case .engineFailed: return L("error.engineFailed")
        }
    }

    /// Сырые подробности (первые ERROR-строки stderr) — для раскрывашки.
    var details: String? {
        if case .engineFailed(let details) = self { return details }
        return nil
    }

    /// Маппинг stderr yt-dlp в понятную ошибку по известным маркерам.
    /// Сначала анализируются ERROR-строки, потом весь вывод: WARNING-строки
    /// (например, «Unable to download webpage» при живом интернете)
    /// не должны перекрывать настоящую причину.
    static func map(stderr: String) -> SavoError {
        let lines = normalizedLines(stderr)
        let all = lines.joined(separator: "\n")
        let errorLines = lines
            .filter { $0.hasPrefix("ERROR:") }
            .joined(separator: "\n")
        if let mapped = match(in: errorLines.isEmpty ? all : errorLines) {
            return mapped
        }
        if let mapped = match(in: all) {
            return mapped
        }
        // Прочее: первая ERROR-строка как подробность.
        return .engineFailed(details: firstErrorDetails(lines) ?? String(all.suffix(400)))
    }

    /// Строки stderr без «\r». yt-dlp печатает `ERROR: \r[download] Got
    /// error: …` — «\r» внутри строки остался от перерисовки прогресса, это
    /// не граница ошибки. Сначала CRLF → LF (в Swift "\r\n" — ОДИН
    /// Character, split по "\n" его не разрежет), затем одиночные «\r» —
    /// в пробел.
    static func normalizedLines(_ stderr: String) -> [String] {
        stderr
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// Подробность для раскрывашки: первая ERROR-строка с текстом. Голое
    /// «ERROR:» (текст ушёл на следующую строку) — берём следующую строку.
    private static func firstErrorDetails(_ lines: [String]) -> String? {
        guard let index = lines.firstIndex(where: { $0.hasPrefix("ERROR:") }) else {
            return nil
        }
        let text = lines[index].dropFirst("ERROR:".count)
            .trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            return lines[index]
        }
        return index + 1 < lines.count ? lines[index + 1] : lines[index]
    }

    private static func match(in text: String) -> SavoError? {
        func has(_ marker: String) -> Bool {
            text.range(of: marker, options: .caseInsensitive) != nil
        }
        if has("Private video") || has("This video is private") {
            return .privateVideo
        }
        if has("not a bot") || has("Sign in to confirm") {
            return .botCheck
        }
        if has("Video unavailable") || has("has been removed") {
            return .videoUnavailable
        }
        if has("HTTP Error 429") || has("Too Many Requests") {
            return .tooManyRequests
        }
        if has("Requested format is not available") {
            return .formatUnavailable
        }
        if has("HTTP Error 403") || has("403 Forbidden") {
            return .forbidden
        }
        if has("This live event will begin") || has("Premieres in") {
            return .liveNotFinished
        }
        if has("Unsupported URL") || has("is not a valid URL") {
            return .unsupportedURL
        }
        if has("Unable to download webpage") || has("Failed to resolve")
            || has("nodename nor servname") || has("Network is unreachable")
            || has("Temporary failure in name resolution") || has("timed out") {
            return .network
        }
        return nil
    }
}
