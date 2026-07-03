#!/bin/bash
# One-line installer for ylty's Stardew Valley co-op panel.

set -e

REPO_URL="https://github.com/ylty1516/puppy-stardew-server-updated.git"
ARCHIVE_URL="https://github.com/ylty1516/puppy-stardew-server-updated/archive/refs/heads/main.tar.gz"
REPO_DIR="${PUPPY_STARDEW_DIR:-puppy-stardew-server-updated}"

info() {
  printf '%s\n' "$1"
}

die() {
  printf '安装失败: %s\n' "$1" >&2
  exit 1
}

run_quick_start() {
  chmod +x quick-start-zh.sh 2>/dev/null || true
  bash quick-start-zh.sh
}

if [ -f "docker-compose.yml" ] && [ -f ".env.example" ] && [ -f "quick-start-zh.sh" ]; then
  info "检测到当前目录已经是项目目录，直接启动中文安装向导。"
  run_quick_start
  exit 0
fi

if [ -d "$REPO_DIR" ]; then
  info "检测到已有目录 $REPO_DIR，进入该目录继续安装。"
  cd "$REPO_DIR" || die "无法进入目录 $REPO_DIR"
  run_quick_start
  exit 0
fi

if command -v git >/dev/null 2>&1; then
  info "正在克隆项目仓库..."
  git clone "$REPO_URL" "$REPO_DIR" || die "克隆仓库失败"
  cd "$REPO_DIR" || die "无法进入目录 $REPO_DIR"
  run_quick_start
  exit 0
fi

info "未检测到 git，尝试下载 main 分支压缩包..."
TMP_ARCHIVE="$(mktemp)"
cleanup() {
  rm -f "$TMP_ARCHIVE"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$ARCHIVE_URL" -o "$TMP_ARCHIVE" || die "下载项目压缩包失败"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$ARCHIVE_URL" -O "$TMP_ARCHIVE" || die "下载项目压缩包失败"
else
  die "需要先安装 git、curl 或 wget 中的任意一个"
fi

command -v tar >/dev/null 2>&1 || die "系统缺少 tar，无法解压项目压缩包"
mkdir -p "$REPO_DIR"
tar -xzf "$TMP_ARCHIVE" --strip-components=1 -C "$REPO_DIR" || die "解压项目压缩包失败"
cd "$REPO_DIR" || die "无法进入目录 $REPO_DIR"

if [ ! -f "quick-start-zh.sh" ]; then
  die "项目文件不完整，缺少 quick-start-zh.sh"
fi

run_quick_start
