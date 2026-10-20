#!/bin/bash
# Сборка Savo.app из SPM-пакета, подпись и установка в ~/Applications.
# Использование: ./build.sh [--dmg]
#   --dmg — дополнительно собрать Savo.dmg в корне репозитория: образ с
#           приложением и симлинком на /Applications — привычная установка
#           перетаскиванием, как у приложений из интернета.
#
# Подпись выбирается сама (как у DOKA): сертификат «Developer ID Application»
# из связки ключей, если он есть, иначе самоподписанный «Savo Dev», иначе
# ad-hoc. Только с Developer ID образ из --dmg уходит на нотаризацию Apple и
# открывается на чужом Mac без «Открыть всё равно» (профиль notarytool —
# SAVO_NOTARY_PROFILE).
#
# Бинарник собирается только под arm64: все Mac пользователя — Apple
# Silicon, Intel не поддерживается.
#
# ВАЖНО: папка проекта лежит на Рабочем столе, который синхронизируется iCloud.
# FileProvider вешает на файлы расширенные атрибуты, из-за которых codesign
# отказывается подписывать бандл («detritus not allowed»). Поэтому бандл
# формируется во временной папке вне iCloud и устанавливается в ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Savo"
# awk, а не `grep | head -1`: head закрыл бы пайп раньше времени, и под
# pipefail присваивание уронило бы сборку.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"Developer ID Application: / && !found { print $2; found = 1 }')"
SIGN_ID="${SAVO_SIGN_ID:-${DEVELOPER_ID:-Savo Dev}}"
NOTARY_PROFILE="${SAVO_NOTARY_PROFILE:-apps-notary}"
INSTALL_DIR="${SAVO_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/${APP_NAME}.app"

MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        *) echo "Неизвестный аргумент: $arg (поддерживается только --dmg)"; exit 1 ;;
    esac
done

# --- Предпроверка вложенного движка (yt-dlp + ffmpeg + deno) -------------
# Бинарники не хранятся в git — их скачивает scripts/fetch-binaries.sh.
# yt-dlp вкладывается onedir-архивом (рабочую копию разворачивает
# EngineInstaller), ffmpeg и deno — бинарниками. Всё обязано нести arm64
# и не быть «облачено» iCloud (пустой файл-заглушка FileProvider ловится
# проверкой размера и целостности архива).
# shellcheck source=scripts/arch.sh
source scripts/arch.sh
for file in yt-dlp_macos.zip yt-dlp.version ffmpeg deno; do
    if [ ! -s "Vendor/bin/$file" ]; then
        echo "ОШИБКА: движок не вложен (Vendor/bin/$file отсутствует или пуст)."
        echo "Запустите scripts/fetch-binaries.sh и повторите сборку."
        exit 1
    fi
done
unzip -tq Vendor/bin/yt-dlp_macos.zip >/dev/null \
    || { echo "ОШИБКА: Vendor/bin/yt-dlp_macos.zip повреждён — перезапустите scripts/fetch-binaries.sh."; exit 1; }
echo "==> Проверка архитектур движка…"
require_arm64 Vendor/bin/ffmpeg "ffmpeg"
require_arm64 Vendor/bin/deno "deno"
CHECK="$(mktemp -d /tmp/savo-ytdlp-check.XXXXXX)"
ditto -x -k --noqtn Vendor/bin/yt-dlp_macos.zip "$CHECK"
require_arm64_tree "$CHECK" "yt-dlp (onedir)"
rm -rf "$CHECK"

echo "==> Сборка release (swift build, arm64)…"
swift build -c release --arch arm64

# Папку продуктов спрашиваем у самого SwiftPM: она зависит от версии
# toolchain (.build/apple/Products/Release у старого, .build/out/Products/
# Release у Swift 6.4). Жёстко прописанный путь однажды молча упаковал
# бинарник двухнедельной давности — сборка «успешна», код старый.
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/${APP_NAME}"
[ -f "$BIN" ] || { echo "Бинарник не найден: $BIN"; exit 1; }
# Защита от устаревшего продукта: ни один исходник не новее бинарника.
# `-print -quit`, а не `| head -1`: head закрыл бы трубу раньше find, тот
# получил бы SIGPIPE, и под pipefail сборка молча упала бы.
STALE="$(find Sources Package.swift -type f -newer "$BIN" -print -quit)"
if [ -n "$STALE" ]; then
    # Ложная тревога бывает штатно: git checkout/pull обновляет время файлов,
    # а содержимое прежнее — SwiftPM сверяет содержимое и не пересобирает.
    # Так случалось перед каждым релизом сразу после `git pull`. Поэтому
    # один раз собираем начисто; осталось старым — это уже настоящая беда.
    echo "    ${STALE} новее бинарника — сборка release начисто…"
    swift package clean
    swift build -c release --arch arm64
    STALE="$(find Sources Package.swift -type f -newer "$BIN" -print -quit)"
    if [ -n "$STALE" ]; then
        echo "ОШИБКА: $BIN старее исходников ($STALE) — сборка его не обновила."
        exit 1
    fi
fi
echo "    Архитектуры: $(lipo -archs "$BIN")"

echo "==> Формирование бандла во временной папке…"
STAGE="$(mktemp -d /tmp/savo-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
STAGE_APP="$STAGE/${APP_NAME}.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
# -X: не копировать расширенные атрибуты (iCloud/FileProvider-мусор)
cp -X "$BIN" "$STAGE_APP/Contents/MacOS/${APP_NAME}"

# Версия SDK в заголовке бинарника (LC_BUILD_VERSION). SwiftPM пишет туда
# sdk = deployment target (14.0), хотя собирает SDK Xcode. AppKit по этой
# пометке решает, давать ли приложению новый дизайн: «собранному под 14» на
# macOS 26/27 достаются СТАРЫЕ кнопки окна, тумблеры, сегменты и спиннеры
# (явный glassEffect при этом работает — это и сбивает с толку). Переписываем
# sdk на фактический; minos — минимальная система из Info.plist (обязана
# совпадать с Package.swift). Только главный бинарник: ffmpeg/deno/yt-dlp —
# консольные, без AppKit. До подписи: vtool её портит, codesign ниже — --force.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
APP_BIN="$STAGE_APP/Contents/MacOS/${APP_NAME}"
vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
    -output "$APP_BIN.sdk" "$APP_BIN"
mv "$APP_BIN.sdk" "$APP_BIN"
# `grep >/dev/null`, а не `grep -q`: с -q otool получает SIGPIPE, и под
# pipefail проверка давала бы ложный отрицательный ответ.
if ! otool -l "$APP_BIN" | grep -E "^ +sdk $SDK_VERSION$" >/dev/null; then
    echo "ОШИБКА: версия SDK в бинарнике не $SDK_VERSION — приложение получит старый вид контролов."
    exit 1
fi
if ! otool -l "$APP_BIN" | grep -E "^ +minos $MIN_MACOS$" >/dev/null; then
    echo "ОШИБКА: minos в бинарнике не $MIN_MACOS (сверить Info.plist и Package.swift)."
    exit 1
fi
echo "    SDK: $SDK_VERSION, минимум macOS $MIN_MACOS"

cp -X "Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"

# Иконка приложения. Регенерация из Resources/AppIcon.png: scripts/make-appicon.sh.
# Именно if/fi: однострочный «[ ] &&» уронил бы сборку под set -e.
if [ -f "Resources/AppIcon.icns" ]; then
    cp -X "Resources/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"
fi

# Локализации уровня бандла (если появятся InfoPlist.strings)
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -RX "$lproj" "$STAGE_APP/Contents/Resources/" || true
done

# Ресурсный бандл SPM-таргета (Localizable.strings ищутся через Bundle.module)
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -RX "$b" "$STAGE_APP/Contents/Resources/" || true
done

# Вложенный движок: onedir-архив yt-dlp с файлом версии + ffmpeg + deno.
# Без Developer ID архив — обычный ресурс: yt-dlp работает на родных ad-hoc
# подписях релиза. С Developer ID его переподписывает sign_ytdlp_archive ниже.
mkdir -p "$STAGE_APP/Contents/Resources/bin"
cp -X Vendor/bin/yt-dlp_macos.zip Vendor/bin/yt-dlp.version Vendor/bin/ffmpeg Vendor/bin/deno \
    "$STAGE_APP/Contents/Resources/bin/"
chmod +x "$STAGE_APP/Contents/Resources/bin/ffmpeg" "$STAGE_APP/Contents/Resources/bin/deno"
xattr -cr "$STAGE_APP" 2>/dev/null || true

echo "==> Подпись…"
# Именно `grep >/dev/null`, а НЕ `grep -q`: с -q grep закрывает пайп на первом
# совпадении, security получает SIGPIPE, и pipefail объявляет находку неудачей.
IS_DEVELOPER_ID=0
if [[ "$SIGN_ID" == "Developer ID Application: "* ]]; then
    IS_DEVELOPER_ID=1
    RESOLVED_SIGN="$SIGN_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$SIGN_ID\"" >/dev/null; then
    RESOLVED_SIGN="$SIGN_ID"
else
    RESOLVED_SIGN="-"
fi

# codesign с меткой времени, с повтором. Сервер меток Apple временами молчит
# («A timestamp was expected but was not found»), особенно после серии
# запросов; разовый сбой не должен ронять сборку. Повторяем подпись с
# нарастающей паузой; любая другая ошибка — сразу наружу.
codesign_timestamped() {
    local delay out
    for delay in 5 20 60 0; do
        if out="$(codesign --timestamp "$@" 2>&1)"; then
            # «replacing existing signature» — штатно для --force, а на архиве
            # yt-dlp это сотня строк шума.
            out="$(grep -v ': replacing existing signature$' <<< "$out" || true)"
            if [ -n "$out" ]; then echo "$out"; fi
            return 0
        fi
        if [ "$delay" = 0 ] || [[ "$out" != *"A timestamp was expected but was not found"* ]]; then
            echo "$out" >&2
            return 1
        fi
        echo "    Нет метки времени от Apple — повтор через ${delay} с…"
        sleep "$delay"
    done
}

# Архив yt-dlp под нотаризацию. Apple распаковывает вложенные архивы и
# проверяет каждый Mach-O: у onedir-сборки релиза все ~100 файлов подписаны
# ad-hoc, и весь образ отклоняется. Поэтому с Developer ID архив
# пересобирается: каждый Mach-O — наша подпись с hardened runtime и меткой
# времени. Прав (entitlements) yt-dlp не нужно: под hardened runtime он,
# curl_cffi и экстракторы работают, если все библиотеки подписаны одной
# командой (иначе dlopen: «different Team IDs» — это ловит проверочный запуск).
sign_ytdlp_archive() {
    local src="$1" dest="$2"
    local tree="$STAGE/yt-dlp-sign" fw version copy file
    local -a versions=() machos=()
    rm -rf "$tree"
    mkdir -p "$tree"
    ditto -x -k --noqtn "$src" "$tree"

    # Каркас Python. В zip релиза его симлинки развёрнуты в копии
    # (Versions/Current, Python, Resources и _internal/Python): такой каркас
    # codesign подписать не может («bundle format is ambiguous»), а у копий
    # нотаризация видит недействительную подпись. Возвращаем стандартное
    # устройство — только если копии побайтно равны оригиналу.
    fw="$tree/_internal/Python.framework"
    if [ -d "$fw" ]; then
        for copy in "$fw"/Versions/*; do
            [ "$(basename "$copy")" = Current ] || versions+=("$(basename "$copy")")
        done
        [ "${#versions[@]}" = 1 ] \
            || { echo "ОШИБКА: в Python.framework не одна версия (${versions[*]:-нет})."; exit 1; }
        version="${versions[0]}"
        for copy in "$fw/Python" "$fw/Versions/Current/Python" "$tree/_internal/Python"; do
            cmp -s "$copy" "$fw/Versions/$version/Python" \
                || { echo "ОШИБКА: ${copy#"$tree"/} не совпадает с каркасом Python — устройство архива yt-dlp поменялось."; exit 1; }
        done
        if ! diff -rq "$fw/Versions/Current" "$fw/Versions/$version" >/dev/null \
            || ! diff -rq "$fw/Resources" "$fw/Versions/$version/Resources" >/dev/null; then
            echo "ОШИБКА: копии в Python.framework расходятся — устройство архива yt-dlp поменялось."
            exit 1
        fi
        rm -rf "$fw/Versions/Current" "$fw/Python" "$fw/Resources" "$tree/_internal/Python"
        ln -s "$version" "$fw/Versions/Current"
        ln -s "Versions/Current/Python" "$fw/Python"
        ln -s "Versions/Current/Resources" "$fw/Resources"
        ln -s "Python.framework/Versions/$version/Python" "$tree/_internal/Python"
        codesign_timestamped --force --options runtime --sign "$RESOLVED_SIGN" "$fw/Versions/$version"
    fi

    # Остальные Mach-O — одним вызовом. Именно [[ ]], а не `file | grep -q`:
    # под pipefail SIGPIPE от grep -q выдал бы Mach-O за обычный файл.
    while IFS= read -r -d '' file; do
        if [[ "$(file -b "$file")" == *Mach-O* ]]; then
            machos+=("$file")
        fi
    done < <(find "$tree" -type f ! -path "$fw/*" -print0)
    [ "${#machos[@]}" -gt 0 ] || { echo "ОШИБКА: в архиве yt-dlp нет Mach-O."; exit 1; }
    codesign_timestamped --force --options runtime --sign "$RESOLVED_SIGN" "${machos[@]}"
    if [ -d "$fw" ]; then
        codesign --verify --strict "$fw"
    fi
    codesign --verify --strict "${machos[@]}"
    # Проверочный запуск: библиотека с чужой подписью под hardened runtime не
    # загрузится. Первый запуск свежих файлов долгий (~10 с проверки macOS).
    "$tree/yt-dlp_macos" --ignore-config --version >/dev/null \
        || { echo "ОШИБКА: подписанный yt-dlp не запускается под hardened runtime."; exit 1; }

    rm -f "$dest"
    # Содержимое каталога без родителя — как в архиве релиза; --norsrc
    # --noextattr: без AppleDouble-файлов (._*) с расширенными атрибутами.
    ditto -c -k --norsrc --noextattr "$tree" "$dest"
    rm -rf "$tree"
    echo "    yt-dlp: ${#machos[@]} Mach-O и каркас Python подписаны (hardened runtime)."
}

# Подпись автора годится для нотаризации как есть: Developer ID, hardened
# runtime и метка времени Apple.
has_vendor_signature() {
    local info
    codesign --verify --strict "$1" 2>/dev/null || return 1
    info="$(codesign -dv --verbose=2 "$1" 2>&1)"
    [[ "$info" == *"Authority=Developer ID Application: "* ]] \
        && [[ "$info" == *"Timestamp="* ]] \
        && grep -E 'flags=0x[0-9a-f]+\([^)]*runtime' <<< "$info" >/dev/null
}

# ffmpeg и deno приходят подписанными их авторами (Developer ID, hardened
# runtime), а у deno ещё и права: allow-jit и др. — без них V8 под hardened
# runtime падает. Такую подпись не трогаем: прежняя переподпись ad-hoc эти
# права молча снимала. Подписываем сами, только если родной подписи нет;
# --preserve-metadata=entitlements сохраняет права, если они были.
if [ "$IS_DEVELOPER_ID" = 1 ]; then
    sign_ytdlp_archive Vendor/bin/yt-dlp_macos.zip "$STAGE_APP/Contents/Resources/bin/yt-dlp_macos.zip"
fi

for tool in ffmpeg deno; do
    TOOL="$STAGE_APP/Contents/Resources/bin/$tool"
    if has_vendor_signature "$TOOL"; then
        # awk без exit: ранний выход оборвал бы пайп (SIGPIPE + pipefail).
        AUTHOR="$(codesign -dv --verbose=2 "$TOOL" 2>&1 \
            | awk -F'Application: ' '/^Authority=Developer ID Application: / && !found { print $2; found = 1 }')"
        echo "    $tool: подпись автора сохранена (${AUTHOR})."
    elif [ "$IS_DEVELOPER_ID" = 1 ]; then
        codesign_timestamped --force --options runtime --preserve-metadata=entitlements \
            --sign "$RESOLVED_SIGN" "$TOOL"
    else
        codesign --force --preserve-metadata=entitlements --sign "$RESOLVED_SIGN" "$TOOL"
    fi
done

# Без --deep: он переподписал бы ffmpeg и deno поверх подписей авторов.
# Другого исполняемого кода в бандле нет (Savo_Savo.bundle — только ресурсы).
if [ "$IS_DEVELOPER_ID" = 1 ]; then
    # Нотаризация требует hardened runtime и метку времени Apple. Прав
    # (entitlements) Savo не нужно: ни микрофона, ни камеры, а запуск
    # движка дочерними процессами hardened runtime не ограничивает.
    codesign_timestamped --force --options runtime --sign "$RESOLVED_SIGN" "$STAGE_APP"
    echo "    Подписано «${SIGN_ID}» (hardened runtime)."
elif [ "$RESOLVED_SIGN" != "-" ]; then
    codesign --force --sign "$RESOLVED_SIGN" "$STAGE_APP"
    echo "    Подписано сертификатом «${SIGN_ID}» (без нотаризации)."
else
    codesign --force --sign - "$STAGE_APP"
    echo "    ВНИМАНИЕ: подпись ad-hoc. Нужен «Developer ID Application» в связке"
    echo "    ключей или сертификат «Savo Dev» (scripts/make-dev-cert.md)."
fi
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

echo "==> Установка в ${APP}…"
mkdir -p "$INSTALL_DIR"
if pgrep -xq "$APP_NAME"; then
    echo "    Savo запущена — завершаю перед заменой."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi
rm -rf "$APP"
mv "$STAGE_APP" "$APP"
echo "==> Готово: $APP"

# Нотаризация файла (zip с приложением или образ) с ожиданием ответа Apple.
# Решаем по статусу из JSON, а не по коду возврата: так различаются «до Apple
# не дошло» (статуса нет) и «Apple отклонила» (статус есть, код всё равно 0).
notarize() {
    local file="$1" json status
    json="$(xcrun notarytool submit "$file" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
    status="$(plutil -extract status raw - <<< "$json" 2>/dev/null)" || true
    if [ -z "$status" ]; then
        echo "    Не удалось отправить на нотаризацию: нет сети или профиля «${NOTARY_PROFILE}»."
        if [ -n "$json" ]; then
            echo "    Ответ notarytool: $json"
        fi
        echo "    Профиль создаётся один раз (спросит пароль приложения от Apple ID):"
        echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <Apple ID> --team-id <Team ID>"
        return 1
    fi
    if [ "$status" != "Accepted" ]; then
        echo "    Apple отклонила $(basename "$file") (статус ${status}). Подробности:"
        xcrun notarytool log "$(plutil -extract id raw - <<< "$json")" \
            --keychain-profile "$NOTARY_PROFILE"
        return 1
    fi
}

if [ "$MAKE_DMG" = 1 ]; then
    DMG_PATH="$(cd .. && pwd)/${APP_NAME}.dmg"
    rm -f "$DMG_PATH"

    if [ "$IS_DEVELOPER_ID" = 1 ]; then
        # Проход 1 — приложение. Квитанция образа приложению, перетащенному
        # из него в «Программы», не достаётся: без своей квитанции Gatekeeper
        # идёт за ней к Apple, а без сети (и для syspolicy_check) это «Notary
        # Ticket Missing». Поэтому приложение нотаризуется и получает
        # квитанцию ДО того, как попасть в образ.
        echo "==> Нотаризация приложения (обычно несколько минут)…"
        APP_ZIP="$STAGE/${APP_NAME}-notary.zip"
        ditto -c -k --keepParent "$APP" "$APP_ZIP"
        notarize "$APP_ZIP" || exit 1
        # Проверяем именно квитанцию, а не `spctl --assess`: при выключенном
        # Gatekeeper spctl примет и ненотаризованное.
        xcrun stapler staple -q "$APP"
        xcrun stapler validate -q "$APP"
    fi

    echo "==> Сборка образа ${DMG_PATH}…"
    # Содержимое образа: приложение + симлинк на /Applications для установки
    # перетаскиванием. Папка-источник — внутри $STAGE (вне iCloud), её
    # подчистит общий trap. Именно ditto: сохраняет подпись, квитанцию и
    # структуру бандла.
    DMG_SRC="$STAGE/dmg"
    mkdir -p "$DMG_SRC"
    ditto "$APP" "$DMG_SRC/${APP_NAME}.app"
    ln -s /Applications "$DMG_SRC/Applications"
    # UDZO — сжатый read-only образ, стандарт раздачи приложений.
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_SRC" \
        -format UDZO -ov -quiet "$DMG_PATH"
    echo "    Готово: $(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')."

    if [ "$IS_DEVELOPER_ID" = 1 ]; then
        # Проход 2 — образ. Подписанный образ Gatekeeper проверяет целиком,
        # ещё до монтирования; квитанция внутри — проверка и без интернета.
        echo "==> Нотаризация образа…"
        codesign_timestamped --force --sign "$RESOLVED_SIGN" "$DMG_PATH"
        notarize "$DMG_PATH" || { rm -f "$DMG_PATH"; exit 1; }
        xcrun stapler staple -q "$DMG_PATH"
        xcrun stapler validate -q "$DMG_PATH"
        echo "    Нотаризованы образ и приложение: на любом Mac откроются без предупреждений."
    else
        echo "    На чужом Mac сертификат «${SIGN_ID}» неизвестен — Gatekeeper заблокирует"
        echo "    первый запуск: правый клик → «Открыть» или Системные настройки →"
        echo "    Конфиденциальность и безопасность → «Открыть всё равно»."
    fi
fi
