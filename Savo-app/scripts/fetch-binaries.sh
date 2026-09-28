#!/bin/bash
# Скачивание вложенного движка Savo в Vendor/bin. Все Mac пользователя —
# Apple Silicon, Intel не поддерживается: ffmpeg и deno качаются только arm64.
#   yt-dlp  — onedir-сборка с GitHub releases (yt-dlp_macos.zip; апстрим
#             выпускает её только universal2 — берём как есть):
#             кладётся АРХИВОМ, рабочую копию из него разворачивает
#             EngineInstaller. Onefile-сборка тратила ~7 с на каждый запуск
#             (распаковка во временную папку + проверка macOS заново),
#             onedir — доли секунды. Сверка SHA-256 по SHA2-256SUMS релиза.
#             Версию можно закрепить: YTDLP_TAG=2026.08.19 scripts/fetch-binaries.sh
#   ffmpeg  — статическая arm64-сборка ffmpeg.martin-riedl.de;
#   deno    — JS-рантайм для YouTube-экстрактора yt-dlp (EJS): без него
#             yt-dlp не решает сигнатуры и теряет большинство форматов;
#             arm64-сборка GitHub releases.
# Запасной источник ffmpeg, если martin-riedl недоступен:
#   https://www.osxexperts.net (вручную)
# Использование: scripts/fetch-binaries.sh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Vendor/bin
TMP="$(mktemp -d /tmp/savo-vendor.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=arch.sh
source scripts/arch.sh

echo "==> Скачивание yt-dlp (onedir, GitHub releases)…"
if [ -n "${YTDLP_TAG:-}" ]; then
    TAG="$YTDLP_TAG"
else
    # /releases/latest перенаправляет на …/releases/tag/<тег>.
    LATEST_URL="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
        https://github.com/yt-dlp/yt-dlp/releases/latest)"
    TAG="${LATEST_URL##*/}"
fi
echo "    релиз: $TAG"
BASE="https://github.com/yt-dlp/yt-dlp/releases/download/$TAG"
curl -fL --retry 3 -o "$TMP/yt-dlp_macos.zip" "$BASE/yt-dlp_macos.zip"
curl -fL --retry 3 -o "$TMP/SHA2-256SUMS" "$BASE/SHA2-256SUMS"
EXPECTED="$(awk '$2 == "yt-dlp_macos.zip" || $2 == "*yt-dlp_macos.zip" { print tolower($1) }' \
    "$TMP/SHA2-256SUMS")"
ACTUAL="$(shasum -a 256 "$TMP/yt-dlp_macos.zip" | awk '{ print $1 }')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "ОШИБКА: SHA-256 yt-dlp_macos.zip не совпала (ожидалась ${EXPECTED:-нет в SUMS}, получена $ACTUAL)."
    exit 1
fi
echo "    SHA-256 совпала"
echo "==> Пробная распаковка и проверка архитектур…"
ditto -x -k --noqtn "$TMP/yt-dlp_macos.zip" "$TMP/ytdlp"
[ -x "$TMP/ytdlp/yt-dlp_macos" ] && [ -d "$TMP/ytdlp/_internal" ] \
    || { echo "ОШИБКА: в архиве нет yt-dlp_macos и _internal/"; exit 1; }
require_arm64_tree "$TMP/ytdlp" "yt-dlp (onedir)"

echo "==> Скачивание ffmpeg (arm64, martin-riedl)…"
curl -fL --retry 3 -o "$TMP/ffmpeg.zip" \
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
unzip -oq "$TMP/ffmpeg.zip" -d "$TMP/ffmpeg_dir"
[ -f "$TMP/ffmpeg_dir/ffmpeg" ] || { echo "ОШИБКА: в архиве нет ffmpeg"; exit 1; }
mv "$TMP/ffmpeg_dir/ffmpeg" "$TMP/ffmpeg"
chmod +x "$TMP/ffmpeg"
xattr -d com.apple.quarantine "$TMP/ffmpeg" 2>/dev/null || true
require_arm64 "$TMP/ffmpeg" "ffmpeg"

echo "==> Скачивание deno (arm64, GitHub releases)…"
curl -fL --retry 3 -o "$TMP/deno.zip" \
    "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
unzip -oq "$TMP/deno.zip" -d "$TMP/deno_dir"
[ -f "$TMP/deno_dir/deno" ] || { echo "ОШИБКА: в архиве нет deno"; exit 1; }
mv "$TMP/deno_dir/deno" "$TMP/deno"
chmod +x "$TMP/deno"
xattr -d com.apple.quarantine "$TMP/deno" 2>/dev/null || true
require_arm64 "$TMP/deno" "deno"

echo "==> Проверка запуска…"
"$TMP/ffmpeg" -version | head -1
"$TMP/deno" --version | head -1
YTDLP_VERSION="$("$TMP/ytdlp/yt-dlp_macos" --ignore-config --version)"
echo "    yt-dlp $YTDLP_VERSION"
if [ "$YTDLP_VERSION" != "$TAG" ]; then
    echo "ОШИБКА: архив сообщил версию $YTDLP_VERSION, ожидалась $TAG."
    exit 1
fi

echo "==> Установка в Vendor/bin…"
mv -f "$TMP/yt-dlp_macos.zip" "$TMP/ffmpeg" "$TMP/deno" Vendor/bin/
# Старый onefile-движок больше не вкладывается в бандл.
rm -f Vendor/bin/yt-dlp
printf '%s' "$YTDLP_VERSION" > Vendor/bin/yt-dlp.version
echo "==> Готово:"
ls -lh Vendor/bin/
