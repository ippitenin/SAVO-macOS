#!/bin/bash
# Проверка локализации Savo: синтаксис .strings, парность ключей ru/en, дубли,
# ключи из кода, мёртвые строки и плейсхолдеры.
#
# Запускается и локально (гейт 1 из CLAUDE.md), и в CI. `swift build` синтаксис
# .strings не проверяет вообще, а рассинхрон ru/en не ловит даже plutil.
#
# Использование: scripts/check-localization.sh   (из Savo-app/ или откуда угодно)
set -uo pipefail
cd "$(dirname "$0")/.."

RU="Sources/Savo/Resources/ru.lproj/Localizable.strings"
EN="Sources/Savo/Resources/en.lproj/Localizable.strings"

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "  ✗ $1"; FAILED=1; }
ok()   { echo "  ✓ $1"; }

# Формат строк строго `"ключ" = "значение";` без экранированных кавычек,
# поэтому разбиение по " даёт ключ в $2 и значение в $4.
keys_of() { awk -F'"' '/^"/ {print $2}' "$1"; }

# Плейсхолдеры значения в порядке появления: %@, %d, %ld, %.1f и подобные.
placeholders_of() {
    awk -F'"' '
    /^"/ {
        val = $4; out = ""
        while (match(val, /%[0-9.]*(@|ld|lu|d|f|s)/)) {
            out = out substr(val, RSTART, RLENGTH) " "
            val = substr(val, RSTART + RLENGTH)
        }
        print $2 "\t" out
    }' "$1" | sort
}

echo "==> Синтаксис"
for f in "$RU" "$EN"; do
    if plutil -lint "$f" >/dev/null; then ok "$f"; else fail "$f: $(plutil -lint "$f")"; fi
done

echo "==> Дубли ключей"
for f in "$RU" "$EN"; do
    dupes="$(keys_of "$f" | sort | uniq -d)"
    if [ -z "$dupes" ]; then ok "$(basename "$(dirname "$f")")"; else fail "$f: $dupes"; fi
done

echo "==> Парность ru/en"
keys_of "$RU" | sort -u > "$TMP/ru"
keys_of "$EN" | sort -u > "$TMP/en"
only_ru="$(comm -23 "$TMP/ru" "$TMP/en")"
only_en="$(comm -13 "$TMP/ru" "$TMP/en")"
[ -z "$only_ru" ] && [ -z "$only_en" ] && ok "$(wc -l < "$TMP/ru" | tr -d ' ') ключей в обоих файлах"
[ -n "$only_ru" ] && fail "только в ru: $(echo "$only_ru" | tr '\n' ' ')"
[ -n "$only_en" ] && fail "только в en: $(echo "$only_en" | tr '\n' ' ')"

echo "==> Ключи из кода"
# Все ключи в коде — литералы `L("…")`; граница слова отсекает URL( и т. п.
grep -rhoE '(^|[^A-Za-z0-9_])L\("[^"]+"' Sources --include='*.swift' \
    | sed -E 's/.*L\("//; s/"$//' | sort -u > "$TMP/code"
missing="$(comm -23 "$TMP/code" "$TMP/ru")"
unused="$(comm -13 "$TMP/code" "$TMP/ru")"
if [ -z "$missing" ]; then ok "$(wc -l < "$TMP/code" | tr -d ' ') ключей из кода есть в .strings"; else fail "нет в .strings: $(echo "$missing" | tr '\n' ' ')"; fi
if [ -z "$unused" ]; then ok "мёртвых строк нет"; else fail "строки не используются в коде: $(echo "$unused" | tr '\n' ' ')"; fi

echo "==> Плейсхолдеры"
placeholders_of "$RU" > "$TMP/ph-ru"
placeholders_of "$EN" > "$TMP/ph-en"
mismatch="$(join -t $'\t' "$TMP/ph-ru" "$TMP/ph-en" | awk -F'\t' '$2 != $3 {print $1}')"
if [ -z "$mismatch" ]; then ok "совпадают"; else fail "расходятся: $(echo "$mismatch" | tr '\n' ' ')"; fi

if [ "$FAILED" = 0 ]; then
    echo "Локализация в порядке."
else
    echo "Локализация с ошибками."
fi
exit "$FAILED"
