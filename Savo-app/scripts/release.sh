#!/bin/bash
# Публикация релиза на GitHub: нотаризованный Savo.dmg, тег и страница релиза.
# Использование: scripts/release.sh — версия берётся из Resources/Info.plist.
#
# Релиз собирается на Mac сопровождающего, а не в CI: сертификат Developer ID
# и профиль нотаризации есть только там (см. «Подпись» в build.sh). CI по тегу
# лишь проверяет, что сборка с чистого раннера проходит (release.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
TAG="v${VERSION}"
DMG="$(cd .. && pwd)/Savo.dmg"

[ "$(git branch --show-current)" = "main" ] || { echo "Релиз собирается только с main"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Есть незакоммиченные изменения"; exit 1; }
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "Локальный main не совпадает с origin/main"; exit 1; }
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "Тег ${TAG} уже есть — поднимите версию в Resources/Info.plist"
    exit 1
fi

./build.sh --dmg
# Нотаризует build.sh только с Developer ID; без него образ на чужом Mac
# потребовал бы «Открыть всё равно», и такой релиз выкладывать нельзя.
xcrun stapler validate -q "$DMG" || { echo "Образ не нотаризован — релиз не публикуется"; exit 1; }

echo "==> Публикация ${TAG}…"
git tag -a "$TAG" -m "Savo for macOS ${TAG}"
git push -q origin "$TAG"
# --generate-notes дописывает под установкой список PR с прошлого релиза.
gh release create "$TAG" "$DMG" --title "Savo for macOS ${TAG}" --generate-notes --notes-file - <<'EOF'
## Installation

Download **Savo.dmg** below, open it and drag Savo to Applications. The app is signed with
Developer ID and notarized by Apple, so it opens like any other app — no extra steps.

The download engine (yt-dlp, ffmpeg, deno) is inside the app. On first launch Savo unpacks it,
which takes a few seconds once; after that the engine keeps itself up to date.

## Requirements

A Mac with Apple silicon (M1 or newer), macOS 14 (Sonoma) or newer. Intel Macs are not supported.

---

## Установка

Скачайте **Savo.dmg** ниже, откройте и перетащите Savo в «Программы». Приложение подписано
Developer ID и нотаризовано Apple, поэтому открывается как обычное — без дополнительных шагов.

Движок скачивания (yt-dlp, ffmpeg, deno) уже внутри приложения. При первом запуске Savo
распаковывает его — это несколько секунд один раз; дальше движок обновляется сам.

## Требования

Mac с чипом Apple (M1 и новее), macOS 14 (Sonoma) или новее. Mac с процессором Intel не поддерживаются.
EOF
echo "==> Готово: $(gh release view "$TAG" --json url -q .url)"
