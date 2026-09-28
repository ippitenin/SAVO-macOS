import Foundation

/// Раскладка движка на диске. Стратегия: бандл — дистрибутив (onedir-архив
/// yt-dlp + ffmpeg + deno), Application Support — рабочая копия; запуск
/// всегда из рабочей копии, обновление подменяет её, не трогая подпись
/// бандла. Корни задаются параметрами — харнесс работает в scratchpad.
struct EngineLayout {
    /// …/Application Support/Savo
    let appSupport: URL
    /// Savo.app/Contents/Resources/bin (nil — dev-запуск без бандла).
    let bundledBin: URL?

    /// Имя onedir-сборки yt-dlp: так называются и каталог, и исполняемый
    /// файл в нём (как в архиве релиза `yt-dlp_macos.zip`).
    static let onedirName = "yt-dlp_macos"

    /// Рабочая копия движка: …/Savo/bin
    var bin: URL { appSupport.appendingPathComponent("bin", isDirectory: true) }
    /// Каталог onedir-сборки: bin/yt-dlp_macos/ (исполняемый + _internal/).
    var ytDlpDir: URL { bin.appendingPathComponent(Self.onedirName, isDirectory: true) }
    var ytDlpOnedir: URL { ytDlpDir.appendingPathComponent(Self.onedirName) }
    /// Версия рабочей копии: пишется при установке ВНУТРЬ каталога и
    /// меняется атомарно вместе с ним.
    var versionFile: URL { ytDlpDir.appendingPathComponent("VERSION") }
    /// Проверенная, но ещё не применённая версия (движок был занят).
    var pendingDir: URL { bin.appendingPathComponent(Self.onedirName + ".pending", isDirectory: true) }
    /// Старый onefile-движок (до перехода на onedir): запасной путь,
    /// пока onedir не установлен и не проверен на этом Mac.
    var legacyYtDlp: URL { bin.appendingPathComponent("yt-dlp") }
    var ffmpeg: URL { bin.appendingPathComponent("ffmpeg") }
    var deno: URL { bin.appendingPathComponent("deno") }
    /// Распаковка и проверка архивов — на том же томе, что bin: подмена
    /// каталога должна быть одним rename.
    var staging: URL { appSupport.appendingPathComponent("engine-staging", isDirectory: true) }
    /// Временная папка загрузок (.part-файлы yt-dlp).
    var tempDownloads: URL { appSupport.appendingPathComponent("tmp", isDirectory: true) }

    var bundledArchive: URL? { bundledBin?.appendingPathComponent(Self.onedirName + ".zip") }
    /// Версия архива в бандле (файл пишет scripts/fetch-binaries.sh).
    var bundledVersionFile: URL? { bundledBin?.appendingPathComponent("yt-dlp.version") }
    var bundledFfmpeg: URL? { bundledBin?.appendingPathComponent("ffmpeg") }
    var bundledDeno: URL? { bundledBin?.appendingPathComponent("deno") }

    /// Исполняемый yt-dlp: onedir, если установлен (его кладёт только
    /// установщик после проверочного запуска), иначе старый onefile.
    var ytDlp: URL {
        FileManager.default.isExecutableFile(atPath: ytDlpOnedir.path) ? ytDlpOnedir : legacyYtDlp
    }

    /// Раскладка рабочей копии yt-dlp — для отчёта об отладке.
    var layoutDescription: String {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: ytDlpOnedir.path) { return "onedir" }
        if fm.isExecutableFile(atPath: legacyYtDlp.path) { return "onefile (старый)" }
        return "не установлен"
    }

    /// Раскладка установленного приложения.
    static var live: EngineLayout {
        EngineLayout(appSupport: EnginePaths.appSupport, bundledBin: EnginePaths.bundledBin)
    }
}

/// Пути движка установленного приложения — короткие обёртки над
/// EngineLayout.live для кода, которому раскладка не важна.
enum EnginePaths {
    /// Папка данных приложения: ~/Library/Application Support/Savo
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Savo", isDirectory: true)
    }

    /// Дистрибутив движка в бандле: Savo.app/Contents/Resources/bin
    static var bundledBin: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
    }

    static var workBin: URL { EngineLayout.live.bin }
    static var workYtDlp: URL { EngineLayout.live.ytDlp }
    static var workFfmpeg: URL { EngineLayout.live.ffmpeg }
    /// JS-рантайм для YouTube-экстрактора (EJS): без него yt-dlp
    /// не решает сигнатуры и теряет большинство форматов.
    static var workDeno: URL { EngineLayout.live.deno }
    /// Временная папка загрузок (.part-файлы yt-dlp): …/Savo/tmp.
    /// «Загрузки» пользователя не засоряются огрызками.
    static var tempDownloads: URL { EngineLayout.live.tempDownloads }
    static var layoutDescription: String { EngineLayout.live.layoutDescription }
}
