#!/bin/bash
# Общие проверки архитектур для fetch-binaries.sh и build.sh.
# Подключается через source. Все Mac пользователя — Apple Silicon, Intel не
# поддерживается: каждый исполняемый файл движка обязан нести arm64-слайс
# (тонкий arm64 или universal — оба годятся).

# В бинарнике есть arm64, иначе — выход с ошибкой.
require_arm64() {
    local path="$1" name="$2"
    local archs
    archs="$(lipo -archs "$path" 2>/dev/null || true)"
    case " $archs " in
        *" arm64 "*) echo "    $name: $archs" ;;
        *)
            echo "ОШИБКА: в $name нет arm64 (архитектуры: ${archs:-нет})."
            exit 1
            ;;
    esac
}

# У каждого Mach-O внутри каталога есть arm64 (onedir-сборка yt-dlp:
# исполняемый файл + ~100 библиотек в _internal/; апстрим собирает её
# universal2 — это нормально).
require_arm64_tree() {
    local root="$1" name="$2"
    local total=0 bad=0 file archs
    while IFS= read -r -d '' file; do
        file -b "$file" | grep -q 'Mach-O' || continue
        total=$((total + 1))
        archs="$(lipo -archs "$file" 2>/dev/null || true)"
        case " $archs " in
            *" arm64 "*) ;;
            *)
                bad=$((bad + 1))
                echo "    нет arm64: ${file#"$root"/} (${archs:-нет})"
                ;;
        esac
    done < <(find "$root" -type f -print0)
    if [ "$total" -eq 0 ] || [ "$bad" -ne 0 ]; then
        echo "ОШИБКА: $name — Mach-O всего $total, без arm64 $bad."
        exit 1
    fi
    echo "    $name: $total Mach-O, у всех есть arm64"
}
