#!/bin/bash
# Сборка Savo.app из SPM-пакета, подпись и установка в ~/Applications.
# Использование: ./build.sh [--zip]
#   --zip — дополнительно упаковать бандл в Savo.zip в корне репозитория
#           (ditto, для передачи на другой Mac).
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
SIGN_ID="${SAVO_SIGN_ID:-Savo Dev}"
INSTALL_DIR="${SAVO_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/${APP_NAME}.app"

MAKE_ZIP=0
for arg in "$@"; do
    case "$arg" in
        --zip) MAKE_ZIP=1 ;;
        *) echo "Неизвестный аргумент: $arg (поддерживается только --zip)"; exit 1 ;;
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
    echo "ОШИБКА: $BIN старее исходников ($STALE) — сборка его не обновила."
    exit 1
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
# Архив для подписи — обычный ресурс: yt-dlp работает на родных ad-hoc
# подписях релиза, hardened runtime не включён — entitlements не нужны.
mkdir -p "$STAGE_APP/Contents/Resources/bin"
cp -X Vendor/bin/yt-dlp_macos.zip Vendor/bin/yt-dlp.version Vendor/bin/ffmpeg Vendor/bin/deno \
    "$STAGE_APP/Contents/Resources/bin/"
chmod +x "$STAGE_APP/Contents/Resources/bin/ffmpeg" "$STAGE_APP/Contents/Resources/bin/deno"
xattr -cr "$STAGE_APP" 2>/dev/null || true

echo "==> Подпись…"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    RESOLVED_SIGN="$SIGN_ID"
else
    RESOLVED_SIGN="-"
    echo "    ВНИМАНИЕ: подпись ad-hoc. Создайте сертификат «${SIGN_ID}»"
    echo "    по инструкции scripts/make-dev-cert.md и пересоберите."
fi
# Подпись «изнутри наружу»: сначала вложенные бинарники движка
# (перезаписываем их родные подписи), затем весь бандл.
codesign --force --sign "$RESOLVED_SIGN" \
    "$STAGE_APP/Contents/Resources/bin/ffmpeg" \
    "$STAGE_APP/Contents/Resources/bin/deno"
codesign --force --deep --sign "$RESOLVED_SIGN" "$STAGE_APP"
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

if [ "$MAKE_ZIP" = 1 ]; then
    ZIP_PATH="$(cd .. && pwd)/${APP_NAME}.zip"
    echo "==> Упаковка в ${ZIP_PATH}…"
    rm -f "$ZIP_PATH"
    # Именно ditto: zip/Finder-архивация не сохраняют подпись и структуру бандла.
    ditto -c -k --keepParent "$APP" "$ZIP_PATH"
    echo "    На чужом Mac сертификат «${SIGN_ID}» неизвестен — Gatekeeper заблокирует"
    echo "    первый запуск: правый клик → «Открыть» или Системные настройки →"
    echo "    Конфиденциальность и безопасность → «Открыть всё равно»."
fi
