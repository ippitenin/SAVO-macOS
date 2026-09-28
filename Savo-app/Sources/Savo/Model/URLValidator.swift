import Foundation

/// Распознавание и нормализация ссылок YouTube. Чистая логика без UI.
enum URLValidator {
    /// Канонический URL видео или nil, если строка не похожа на ссылку
    /// YouTube. Понимает watch / youtu.be / live / shorts / embed,
    /// мобильный и music-домены; параметры плейлиста отбрасываются.
    static func canonicalURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased() else { return nil }

        let id: String?
        switch host {
        case "youtu.be":
            id = firstPathComponent(components)
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            let path = components.path
            if path == "/watch" {
                id = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if path.hasPrefix("/live/") || path.hasPrefix("/shorts/") || path.hasPrefix("/embed/") {
                id = components.path.split(separator: "/").dropFirst().first.map(String.init)
            } else {
                id = nil
            }
        default:
            return nil
        }

        guard let id, isValidVideoID(id) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    private static func firstPathComponent(_ components: URLComponents) -> String? {
        components.path.split(separator: "/").first.map(String.init)
    }

    /// Идентификатор видео YouTube: 11 символов [A-Za-z0-9_-].
    private static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
}
