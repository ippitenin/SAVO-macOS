#!/bin/bash
# Сборка и запуск: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
open "${SAVO_INSTALL_DIR:-$HOME/Applications}/Savo.app"
