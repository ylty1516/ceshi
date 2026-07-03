#!/usr/bin/env bash
# ylty 的星露谷联机面板 - 一行安装脚本
#
# 推荐用法：
#   curl -fsSL https://raw.githubusercontent.com/ylty1516/puppy-stardew-server-updated/main/install.sh | bash
#
# 可选环境变量：
#   YLTY_INSTALL_DIR=/opt/ylty-stardew-panel
#   STEAM_USERNAME=your_name STEAM_PASSWORD=your_password
#   YLTY_AUTO_START=yes|no|ask

set -Eeuo pipefail

REPO_URL="${YLTY_REPO_URL:-https://github.com/ylty1516/puppy-stardew-server-updated.git}"
BRANCH="${YLTY_BRANCH:-main}"
INSTALL_DIR="${YLTY_INSTALL_DIR:-$HOME/ylty-stardew-panel}"
AUTO_START="${YLTY_AUTO_START:-ask}"

DOCKER=()
COMPOSE=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info() { printf "${BLUE}%s${NC}\n" "$*"; }
ok() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
fail() { printf "${RED}%s${NC}\n" "$*" >&2; exit 1; }
step() { printf "\n${BOLD}%s${NC}\n" "$*"; }

usage() {
  cat <<EOF
ylty 的星露谷联机面板安装脚本

用法:
  bash install.sh [选项]

选项:
  --dir <path>       安装目录，默认: $INSTALL_DIR
  --repo-url <url>   Git 仓库地址，默认: $REPO_URL
  --branch <name>    分支，默认: $BRANCH
  --start            安装后直接启动
  --no-start         只安装和生成配置，不启动
  --help             显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || fail "--dir 需要路径参数"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --repo-url)
      [ "$#" -ge 2 ] || fail "--repo-url 需要 URL 参数"
      REPO_URL="$2"
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || fail "--branch 需要分支名"
      BRANCH="$2"
      shift 2
      ;;
    --start)
      AUTO_START="yes"
      shift
      ;;
    --no-start)
      AUTO_START="no"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

has_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

ask() {
  local __var="$1"
  local prompt="$2"
  local default="${3:-}"
  local answer=""

  if ! has_tty; then
    [ -n "$default" ] || return 1
    printf -v "$__var" "%s" "$default"
    return 0
  fi

  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default" > /dev/tty
  else
    printf "%s: " "$prompt" > /dev/tty
  fi

  read -r answer < /dev/tty || answer=""
  if [ -z "$answer" ]; then
    answer="$default"
  fi
  printf -v "$__var" "%s" "$answer"
}

ask_secret() {
  local __var="$1"
  local prompt="$2"
  local answer=""

  has_tty || return 1
  printf "%s: " "$prompt" > /dev/tty
  stty -echo < /dev/tty
  read -r answer < /dev/tty || answer=""
  stty echo < /dev/tty
  printf "\n" > /dev/tty
  printf -v "$__var" "%s" "$answer"
}

confirm() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer=""
  local suffix="[Y/n]"

  [ "$default" = "yes" ] || suffix="[y/N]"

  if ! has_tty; then
    [ "$default" = "yes" ]
    return
  fi

  printf "%s %s " "$prompt" "$suffix" > /dev/tty
  read -r answer < /dev/tty || answer=""
  answer="${answer:-$default}"

  case "$answer" in
    y|Y|yes|YES|Yes|是) return 0 ;;
    *) return 1 ;;
  esac
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped=""
  escaped="$(printf '%s' "$value" | sed -e 's/[\/&\\]/\\&/g')"

  if grep -q "^${key}=" .env; then
    sed -i.bak "s/^${key}=.*/${key}=${escaped}/" .env
    rm -f .env.bak
  else
    printf "%s=%s\n" "$key" "$value" >> .env
  fi
}

get_server_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -4 -fsS --max-time 3 https://ip.sb 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf "%s" "${ip:-你的服务器IP}"
}

print_header() {
  cat <<'EOF'

============================================================
  ylty 的星露谷联机面板 - 快速安装
============================================================

EOF
}

check_requirements() {
  step "1. 检查运行环境"

  command -v git >/dev/null 2>&1 || fail "未安装 git。请先执行: sudo apt-get update && sudo apt-get install -y git"
  command -v sed >/dev/null 2>&1 || fail "未找到 sed，请检查系统环境。"

  if ! command -v docker >/dev/null 2>&1; then
    fail "未安装 Docker。请先执行: curl -fsSL https://get.docker.com | sh"
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    fail "Docker 未运行或当前用户没有权限。可尝试: sudo systemctl start docker && sudo usermod -aG docker \$USER"
  fi

  if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    COMPOSE=("${DOCKER[@]}" compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    if docker-compose version >/dev/null 2>&1; then
      COMPOSE=(docker-compose)
    elif command -v sudo >/dev/null 2>&1 && sudo docker-compose version >/dev/null 2>&1; then
      COMPOSE=(sudo docker-compose)
    fi
  fi

  [ "${#COMPOSE[@]}" -gt 0 ] || fail "未安装 Docker Compose。Ubuntu/Debian 可执行: sudo apt-get install -y docker-compose-plugin"
  ok "Docker 和 Docker Compose 可用"
}

prepare_repo() {
  step "2. 获取项目文件"

  if [ -f "docker-compose.yml" ] && [ -f ".env.example" ] && [ -d "docker" ]; then
    INSTALL_DIR="$(pwd)"
    ok "检测到当前目录已经是项目目录: $INSTALL_DIR"
    return
  fi

  mkdir -p "$(dirname "$INSTALL_DIR")"

  if [ -d "$INSTALL_DIR/.git" ]; then
    info "安装目录已存在，正在更新: $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch origin "$BRANCH"
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
  else
    info "克隆仓库到: $INSTALL_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi

  cd "$INSTALL_DIR"
  ok "项目文件准备完成"
}

configure_env() {
  step "3. 生成 .env 配置"

  [ -f ".env.example" ] || fail "未找到 .env.example，项目文件不完整。"

  if [ -f ".env" ]; then
    if confirm "检测到已有 .env，是否重新填写 Steam 配置？" "no"; then
      cp .env ".env.backup.$(date +%Y%m%d-%H%M%S)"
    else
      ok "保留现有 .env"
      return
    fi
  fi

  cp .env.example .env

  local steam_user="${STEAM_USERNAME:-}"
  local steam_pass="${STEAM_PASSWORD:-}"
  local vnc_pass="${VNC_PASSWORD:-}"
  local public_ip="${PUBLIC_IP:-}"

  if [ -z "$steam_user" ]; then
    ask steam_user "请输入 Steam 用户名" "" || fail "无法读取 Steam 用户名。也可以用 STEAM_USERNAME=xxx 环境变量传入。"
  fi
  if [ -z "$steam_pass" ]; then
    ask_secret steam_pass "请输入 Steam 密码（输入不会显示）" || fail "无法读取 Steam 密码。也可以用 STEAM_PASSWORD=xxx 环境变量传入。"
  fi

  [ -n "$steam_user" ] || fail "Steam 用户名不能为空。"
  [ -n "$steam_pass" ] || fail "Steam 密码不能为空。"

  if [ -z "$vnc_pass" ] && has_tty; then
    ask vnc_pass "VNC 密码（最多 8 位，留空则容器启动时自动生成）" ""
  fi
  if [ "${#vnc_pass}" -gt 8 ]; then
    warn "VNC 协议只支持最多 8 位密码，已自动截断。"
    vnc_pass="${vnc_pass:0:8}"
  fi

  if [ -z "$public_ip" ] && has_tty; then
    ask public_ip "公网 IP 或域名（可留空，面板会自动探测）" ""
  fi

  set_env_value "STEAM_USERNAME" "$steam_user"
  set_env_value "STEAM_PASSWORD" "$steam_pass"
  set_env_value "VNC_PASSWORD" "$vnc_pass"
  [ -n "$public_ip" ] && set_env_value "PUBLIC_IP" "$public_ip"
  chmod 600 .env 2>/dev/null || true

  ok ".env 已生成"
}

setup_directories() {
  step "4. 初始化数据目录权限"

  mkdir -p data/saves data/game data/steam data/logs data/backups data/custom-mods data/panel

  if chown -R 1000:1000 data/ 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown -R 1000:1000 data/
  else
    fail "无法设置 data 目录权限。请手动执行: sudo chown -R 1000:1000 data/"
  fi

  local owner=""
  owner="$(stat -c '%u' data/game 2>/dev/null || stat -f '%u' data/game 2>/dev/null || true)"
  [ "$owner" = "1000" ] || fail "data/game 权限不是 UID 1000，游戏下载可能失败。请执行: sudo chown -R 1000:1000 data/"

  ok "数据目录已就绪"
}

start_server() {
  step "5. 构建并启动服务"

  if [ "$AUTO_START" = "ask" ]; then
    if confirm "是否现在启动服务？首次启动会下载游戏文件，可能需要几分钟。" "yes"; then
      AUTO_START="yes"
    else
      AUTO_START="no"
    fi
  fi

  if [ "$AUTO_START" != "yes" ]; then
    warn "已跳过启动。之后可在项目目录执行: ${COMPOSE[*]} up -d --build"
    return
  fi

  "${COMPOSE[@]}" up -d --build
  ok "服务启动命令已执行"
}

show_next_steps() {
  local ip=""
  ip="$(get_server_ip)"

  cat <<EOF

============================================================
安装完成
============================================================

项目目录:
  $INSTALL_DIR

Web 管理面板:
  http://$ip:18642

游戏联机端口:
  24642/udp

常用命令:
  查看日志:   ${DOCKER[*]} logs -f puppy-stardew
  停止服务:   ${COMPOSE[*]} down
  重启服务:   ${COMPOSE[*]} up -d --build
  健康检查:   ./health-check.sh

首次启动如果需要 Steam Guard 验证码:
  ${DOCKER[*]} attach puppy-stardew

输入验证码后等待几秒，再按 Ctrl+P 然后 Ctrl+Q 退出 attach。

EOF
}

main() {
  print_header
  check_requirements
  prepare_repo
  configure_env
  setup_directories
  start_server
  show_next_steps
}

main
