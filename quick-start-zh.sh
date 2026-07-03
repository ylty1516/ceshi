#!/usr/bin/env bash
# 中文兼容入口：统一转到 install.sh，避免安装到上游原版仓库。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/install.sh" ]; then
  exec bash "$SCRIPT_DIR/install.sh" "$@"
fi

curl -fsSL https://raw.githubusercontent.com/ylty1516/puppy-stardew-server-updated/main/install.sh | bash -s -- "$@"
