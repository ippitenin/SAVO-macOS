# SAVER / Savo (ранее Fetcha)

Savo — личное нативное macOS-приложение для скачивания видео с YouTube-канала пользователя (эфиры по дизайну: открытые и «доступ по ссылке»). Сценарий: вставил ссылку → карточка с превью → выбрал качество (видео / только аудио с битрейтом / видео без звука) → скачал в «Загрузки» → «Показать в Finder». Все Mac пользователя — Apple Silicon (M-серия): приложение и ffmpeg/deno собираются только под arm64, Intel не поддерживается.

Весь текст, комментарии в коде и коммиты — на русском. Строки интерфейса — только через `L("ключ")`, каждый ключ обязан быть в обоих `Sources/Savo/Resources/{ru,en}.lproj/Localizable.strings`; после правок `.strings` обязателен `plutil -lint` (swift build их не валидирует).

## Структура

- `Savo-app/` — SPM executable-таргет (НЕ Xcode-проект), macOS 14+, зависимостей нет. AppKit-каркас (main.swift → AppDelegate → WindowManager/NSWindow), контент на SwiftUI.
- `Savo-app/Sources/Savo/Engine/` — слой движка: EnginePaths (EngineLayout — раскладка, корни параметром для харнесса), EngineInstaller, EngineArchive, EngineUpdater, EngineGate, EngineBootstrap, EngineVersion, ProcessRunner (все запуски внешних бинарников, включая ditto, только через него), YtDlpClient, ProgressParser, SavoError (файл `FetchaError.swift` — старое имя), EngineStatus, EngineLog.
- `Savo-app/Sources/Savo/Storage/` — HistoryStore + DownloadRecord/HistoryCodec, SettingsStore. `Diagnostics/DiagnosticsReport.swift` — «Скопировать отчёт» в настройках.
- `Savo-app/Sources/Savo/Model/` — чистая тестопригодная логика: URLValidator, VideoInfo, DownloadPreset/PresetBuilder. Качество подписывается СТУПЕНЬЮ YouTube (`PresetBuilder.qualityTier`: наименьшая рамка 16:9, куда кадр влезает в любой ориентации), а селектор yt-dlp — фактической высотой кадра: у ролика 2:1 «1080p» — это `height=960`, у вертикального 1080×1920 — `height=1920`. Подпись высотой в пикселях давала «1920p», «428p».
- `Savo-app/Sources/Savo/Controllers/DownloadController.swift` — конечный автомат `idle → fetchingInfo → ready → downloading → done/failed`; переходы только через `transition(to:)`, счётчик `generation` инвалидирует устаревшие задачи; обновления прогресса пишутся в `state` напрямую (без бампа generation).
- `Savo-app/Sources/Savo/UI/DesignSystem/` — дизайн-токены `DS` (единственный источник правды: цвета/радиусы/отступы/анимации, НЕ хардкодить в вью), `glassSurface()`/`glassCapsule()` для всего «стекла», mesh-фон. Палитра — розовая: слива #4A1042 → фуксия-акцент #E0338F → пыльно-розовый; жёлтая риска #F4D03F — метка прогресса. Под macOS 26/27 (перенесено из DOKA, коммиты eaff801/190f4ce): кнопки — один свой `DSCapsuleButtonStyle` (сплошная фуксия у главной), НЕ `.glassProminent`/`.glass` (стекло мутит цвет, на macOS 27 теряется капсула, вторичная выше главной); кромка окна `EdgeRim` — `ConcentricRectangle` (macOS 26+), радиус числом не зашивать; высокие карточки в ScrollView (история, выбор качества) — `glassSurface(forceMaterial: true)`, иначе серая плита под стеклом и отражения соседей; плоским кнопкам — `.focusEffectDisabled()`. Файлы DOKA целиком не копировать: у неё минимум macOS 15, у Savo 14.
- `Savo-app/Vendor/bin/` — вложенный движок (`yt-dlp_macos.zip` + `yt-dlp.version`, ffmpeg, deno), НЕ в git; скачивает `scripts/fetch-binaries.sh` (SHA-256 по SHA2-256SUMS, версию можно закрепить `YTDLP_TAG=…`), всё обязано нести arm64 (`scripts/arch.sh`); yt-dlp-архив апстрим выпускает только universal2 — берётся как есть.

## Движок (не «чинить»)

- Стратегия «бандл — дистрибутив, App Support — рабочая копия»: запуск всегда из `~/Library/Application Support/Savo/bin/`, подпись бандла обновления не трогают.
- yt-dlp — ONEDIR-сборка (`yt-dlp_macos.zip` релиза), НЕ onefile: onefile тратил ~7 с на КАЖДЫЙ запуск (распаковка во временную папку + повторная проверка macOS), onedir — ~0,2 с (дорог только первый запуск свежих файлов; rename прогрев не сбрасывает). В бандле лежит архивом; EngineInstaller/EngineArchive: `ditto -x -k --noqtn` → снятие quarantine → проверочный `--version` → файл `bin/yt-dlp_macos/VERSION` → атомарная подмена (`renamex_np` RENAME_SWAP). Бандл ставится, только если он новее ФАКТИЧЕСКОЙ `VERSION` рабочей копии (иначе новая сборка откатила бы обновлённый движок). ffmpeg/deno копируются файлами.
- Для onedir `yt-dlp -U` НЕ работает (`darwin_dir`) — обновляет свой EngineUpdater: HEAD `/releases/latest` → zip + SHA2-256SUMS → сверка SHA-256 → EngineArchive.prepare → `bin/yt-dlp_macos.pending/` → применение, когда в EngineGate нет аренд. Каждый запуск yt-dlp держит аренду EngineGate: onedir лениво читает `_internal`, подмена под живым процессом его уронит. Автопроверка раз в сутки (настройка «Проверять автоматически», по умолчанию вкл).
- deno обязателен: без JS-рантайма YouTube-экстрактор yt-dlp не решает сигнатуры и теряет большинство форматов. Каждый вызов yt-dlp идёт с `--js-runtimes deno:<путь>` (см. `YtDlpClient.baseArguments`).
- `--print after_move:filepath` подразумевает `--simulate`, поэтому в аргументах скачивания обязательны `--no-simulate` и `--progress`.
- Временные .part-файлы — в `…/Savo/tmp` (`-P temp:`), «Загрузки» не засоряются; отмена чистит tmp.
- Имя файла: `%(title).150B [дд.мм.гггг, <метка пресета>].%(ext)s` (`DownloadPreset.outputTemplate`): без метки 720p после 1080p того же ролика yt-dlp счёл бы «уже скачанным» и молча вернул старый файл; дата различает одноимённые эфиры; предел — в БАЙТАХ (санитизация раздувает «|» → «｜»).
- `--ignore-config` и `--ffmpeg-location` — в `baseArguments` (без ffmpeg-location `-J` предупреждает «ffmpeg not found»).
- `~/Library/Logs/Savo/engine.log`: аргументы, код выхода, ДЛИТЕЛЬНОСТЬ и stderr каждого запуска + служебные события `[savo]` (установка/обновление движка, история).
- История: новые поля `DownloadRecord` — ТОЛЬКО опциональные; HistoryCodec отбрасывает битые записи поштучно, исходник при этом уходит в `history.json.bak`.
- YouTube может отвечать 429/«не робот» (после многих запросов подряд) — это временно, у ошибок есть свои кейсы SavoError (botCheck/tooManyRequests). 403/бот-чек/нет формата сначала лечатся сменой клиента (`YtDlpClient.clientAttempts`: по умолчанию → `web_embedded`; 429 НЕ повторяется — повтор усугубляет лимит); если не помогло — сообщение «подождите и попробуйте снова». «Обновите движок в настройках» советует только badMetadata; свежесть движка держит автопроверка.

## Сборка (не «чинить»)

- **Пометка SDK в бинарнике (`LC_BUILD_VERSION`) переписывается `vtool` в `build.sh`.** SwiftPM пишет туда `sdk` = deployment target (14.0), а AppKit по этой пометке решает, давать ли новый дизайн: «собранному под 14» на macOS 26/27 достаются СТАРЫЕ светофор, тумблеры, сегменты, спиннеры (явный glassEffect при этом работает — это и сбивает с толку). `build.sh` ставит `sdk` = `xcrun --show-sdk-version`, `minos` = `LSMinimumSystemVersion` и падает, если пометка не совпала. Голые `swift build`/`swift run` по-прежнему дают `sdk 14.0` — вид контролов проверять только на бандле из `build.sh`. Первым делом при «устаревшем виде»: `otool -l <бинарник> | grep -A4 LC_BUILD_VERSION`.
- `swift build` — быстрая проверка (если падает подпись `Savo_Savo.bundle` с «detritus» — iCloud успел навесить xattr на `.build`; собирать с `--scratch-path` вне iCloud); `./build.sh` — arm64-сборка, подпись, установка в `~/Applications`; `./build.sh --zip` — Savo.zip для передачи на второй Mac; `./run.sh` — сборка + запуск.
- Проект на Рабочем столе (iCloud): FileProvider вешает xattr, codesign падает («detritus not allowed») — бандл собирается во временной папке /tmp, `cp -X`, `xattr -cr`. Не подписывать внутри папки проекта.
- Папка продуктов release-сборки зависит от toolchain (`.build/apple/Products/Release/` у старого SwiftPM, `.build/out/Products/Release/` у Swift 6.4) — `build.sh` спрашивает её через `--show-bin-path` и падает, если бинарник старее исходников. Жёсткий путь однажды молча упаковал бинарник двухнедельной давности.
- Подпись «изнутри наружу»: сначала ffmpeg и deno, потом весь бандл; `codesign --verify --deep --strict`. Архив yt-dlp для подписи — обычный ресурс: его содержимое работает на родных ad-hoc подписях релиза (hardened runtime не включён — entitlements не нужны). Сертификат «Savo Dev» (env `SAVO_SIGN_ID`), без него ad-hoc; инструкция — `scripts/make-dev-cert.md`.
- Иконка: `scripts/make-appicon.sh` из `Resources/AppIcon.png` (контент 822/1024, скругление 22,5%).

## Верификация (тестов нет — гейты)

1. `swift build` без ворнингов; `plutil -lint` Info.plist и всех `.strings`.
2. `./build.sh` проходит (сам проверяет arm64 во всех Mach-O внутри `yt-dlp_macos.zip`); `lipo -archs` бинарника приложения и ffmpeg/deno в бандле → `arm64`; `codesign --verify --deep --strict ~/Applications/Savo.app`. После первого запуска: есть `…/Savo/bin/yt-dlp_macos/VERSION`, нет старого `bin/yt-dlp`, `time …/yt-dlp_macos --version` < 1 с.
3. Чистая логика (URLValidator, PresetBuilder/DownloadPreset.outputTemplate, ProgressParser, SavoError.map, HistoryCodec, EngineInstaller.plan, EngineVersion, EngineUpdater.parseChecksums/isDue) проверяется scratchpad-harness'ом: `swiftc` реальных исходников + шим `L()` (читает настоящие `.strings`) + main с кейсами. Установщик/апдейтер — на EngineLayout в scratchpad с фейковыми zip (`ditto -c -k`). EngineInstaller и HistoryStore пишут события в НАСТОЯЩИЙ `engine.log` — в харнессе их подменять фейковым EngineLog (однажды тест истории оставил в журнале ложные «отброшено битых записей»).
4. Ручной smoke: ссылка → карточка → скачивание 1080p (открывается в QuickTime), MP3, «без звука»; отмена не оставляет мусора; смена папки в настройках действует; история переживает перезапуск. Помнить о лимите YouTube: одна загрузка за сессию проверки. На втором Mac — «Скопировать отчёт» в настройках (модель Mac, замеры старта движка, карантин).

## Репозиторий и Git

- Публичный репозиторий `github.com/ippitenin/SAVO-macOS`, лицензия GPL-3.0 (`LICENSE`). В корне: `CLAUDE.md`, `README.md` (английский) + `README.ru.md` (русский), `Savo-app/`.
- В `main` — ТОЛЬКО через pull request: ветка `feat/…`, `fix/…`, `docs/…`, `chore/…` → PR → слияние merge-коммитом. Коммиты и PR — на русском, с префиксом (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`); в описании PR — «Что внутри» и чек-лист проверок (гейты ниже), как у DOKA.
- Пользовательские изменения обновляют ОБА README (en/ru) в том же PR; правила и ловушки — сюда, в CLAUDE.md.
- Не в git: `Savo-app/.build/`, `Savo-app/Vendor/bin/` (движок качает `scripts/fetch-binaries.sh`), `Savo.zip` (`build.sh --zip`), `DOCS/` (унаследованный шаблон: Rails-инструкции и дизайн-процессы к проекту не относятся; локально актуальны только общие правила стиля работы в `DOCS/ОБЩИЕ-ИНСТРУКЦИИ/`). Харнессы проверки живут в scratchpad сессии, в репозиторий не кладутся.

## Референс

Код и паттерны — приложение DOKA того же автора: соседний репозиторий `github.com/ippitenin/DOKA-macOS` (локально `../DOKA-macOS/DOKA-app`; правила — `DOKA-macOS/CLAUDE.md`, там же ловушки дизайна под macOS 26/27).
