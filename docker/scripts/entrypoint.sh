#!/bin/bash
# Puppy Stardew Server Entrypoint Script - v1.1.0
# 小狗星谷服务器启动脚本 - v1.1.0

# DO NOT use set -e - we need manual error handling
# 不使用 set -e - 需要手动错误处理

# Color codes for pretty logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PANEL_ENV_FILE=${ENV_FILE:-/home/steam/web-panel/data/runtime.env}
PUPPY_META_DIR=${PUPPY_META_DIR:-/home/steam/web-panel/data/meta}
ORCHESTRATION_STATE_FILE=${ORCHESTRATION_STATE_FILE:-$PUPPY_META_DIR/orchestration-state.json}
STEAM_JSON_SECRET=${STEAM_JSON_SECRET:-/home/steam/secrets/steam.json}
FORCE_STEAM_UPDATE_MARKER=${FORCE_STEAM_UPDATE_MARKER:-/home/steam/web-panel/data/panel/force-game-update}
STEAM_UPDATE_ON_START=${STEAM_UPDATE_ON_START:-false}

if [ ! -f "$PANEL_ENV_FILE" ] && [ -f "/home/steam/.env" ]; then
    PANEL_ENV_FILE="/home/steam/.env"
fi

decode_panel_env_value() {
    local value="$1"
    value="${value%$'\r'}"

    if [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\'/\'}"
    elif [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\n/$'\n'}"
        value="${value//\\r/$'\r'}"
        value="${value//\\t/$'\t'}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
    else
        value="${value%% #*}"
    fi

    printf '%s' "$value"
}

load_panel_env_overrides() {
    local env_file=${1:-$PANEL_ENV_FILE}

    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac

        local key=${line%%=*}
        local value=${line#*=}

        case "$key" in
            ''|*[!A-Za-z0-9_]*)
                continue
                ;;
        esac

        value=$(decode_panel_env_value "$value")
        export "$key=$value"
    done < "$env_file"
}

load_panel_env_overrides

# Resolution and performance environment variables with defaults
DEFAULT_RESOLUTION_WIDTH=1280
DEFAULT_RESOLUTION_HEIGHT=720
DEFAULT_REFRESH_RATE=60
LOW_PERF_DEFAULT_WIDTH=800
LOW_PERF_DEFAULT_HEIGHT=600
LOW_PERF_DEFAULT_FPS=30
LOW_PERF_DEFAULT_COLOR_DEPTH=16

LOW_PERF_MODE=${LOW_PERF_MODE:-false}
MAX_PLAYERS=${MAX_PLAYERS:-8}
TARGET_FPS_RAW=${TARGET_FPS:-}
RESOLUTION_WIDTH=${RESOLUTION_WIDTH:-$DEFAULT_RESOLUTION_WIDTH}
RESOLUTION_HEIGHT=${RESOLUTION_HEIGHT:-$DEFAULT_RESOLUTION_HEIGHT}
REFRESH_RATE=${REFRESH_RATE:-${TARGET_FPS_RAW:-$DEFAULT_REFRESH_RATE}}
TARGET_FPS=${TARGET_FPS_RAW:-$REFRESH_RATE}
XVFB_COLOR_DEPTH=24
XVFB_FB_DIR=""
XVFB_FB_ARGS=()

# Logging functions
log_info() {
    echo -e "${GREEN}[Puppy-Stardew]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Puppy-Stardew]${NC} $1"
}

log_error() {
    echo -e "${RED}[Puppy-Stardew]${NC} $1"
}

log_step() {
    echo -e "${BLUE}${1}${NC}"
}

log_steam() {
    echo -e "${CYAN}$1${NC}"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_orchestration_state() {
    local state=$1
    local phase=$2
    local message=${3:-}
    local now

    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    mkdir -p "$(dirname "$ORCHESTRATION_STATE_FILE")" 2>/dev/null || return 0
    cat > "$ORCHESTRATION_STATE_FILE" <<JSON
{
  "state": "$(json_escape "$state")",
  "phase": "$(json_escape "$phase")",
  "message": "$(json_escape "$message")",
  "updatedAt": "$now",
  "source": "entrypoint"
}
JSON
}

fail_startup() {
    local phase=$1
    local message=$2
    local code=${3:-1}

    write_orchestration_state "STOPPED" "$phase" "$message"
    log_error "$message"
    exit "$code"
}

get_mod_manifest_version() {
    local mod_dir=$1
    local manifest="$mod_dir/manifest.json"

    if [ ! -f "$manifest" ]; then
        echo ""
        return 0
    fi

    awk -F'"' '/"Version"[[:space:]]*:/ { print $4; exit }' "$manifest" 2>/dev/null || true
}

server_autoload_config_is_legacy() {
    local config_file=$1

    [ -f "$config_file" ] || return 1
    grep -q '"EnableAutoLoad"' "$config_file" && return 0
    grep -q '"StateFile"' "$config_file" || return 0
    grep -q '"SelectedSaveMarker"' "$config_file" || return 0
    grep -q '"Enabled"' "$config_file" || return 0
    return 1
}

repair_server_autoload_config_if_legacy() {
    local source_mod=$1
    local target_mod=$2
    local backup_root=$3
    local timestamp=$4
    local old_config="$target_mod/config.json"
    local source_config="$source_mod/config.json"
    local config_backup_dir

    [ -f "$source_config" ] || return 0
    server_autoload_config_is_legacy "$old_config" || return 0

    config_backup_dir="$backup_root/$timestamp"
    mkdir -p "$config_backup_dir" || return 0
    cp -a "$old_config" "$config_backup_dir/ServerAutoLoad.legacy.config.json" 2>/dev/null || true
    log_warn "  ServerAutoLoad legacy config detected; replacing with v2 native Co-op Host config"
    cp -a "$source_config" "$old_config" 2>/dev/null || true
}

sync_preinstalled_mods() {
    local source_root="/home/steam/preinstalled-mods"
    local target_root="/home/steam/stardewvalley/Mods"
    local backup_root="/home/steam/web-panel/data/preinstalled-mod-backups"
    local timestamp
    local source_mod

    [ -d "$source_root" ] || return 0

    timestamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$target_root"

    log_info "Syncing bundled server mods..."
    shopt -s nullglob
    for source_mod in "$source_root"/*; do
        [ -d "$source_mod" ] || continue

        local mod_name
        local target_mod
        local bundled_version
        local installed_version
        local mod_backup_root
        local config_backup=""
        local preserve_config="true"

        mod_name=$(basename "$source_mod")
        target_mod="$target_root/$mod_name"
        bundled_version=$(get_mod_manifest_version "$source_mod")
        installed_version=$(get_mod_manifest_version "$target_mod")

        if [ ! -d "$target_mod" ]; then
            log_info "  Installing bundled mod: $mod_name${bundled_version:+ v$bundled_version}"
            cp -a "$source_mod" "$target_mod" || {
                log_warn "  Failed to install bundled mod: $mod_name"
                continue
            }
            continue
        fi

        if [ -z "$bundled_version" ]; then
            log_warn "  Bundled mod $mod_name has no manifest version; leaving installed copy untouched"
            continue
        fi

        if [ "$bundled_version" = "$installed_version" ]; then
            if [ "$mod_name" = "ServerAutoLoad" ]; then
                repair_server_autoload_config_if_legacy "$source_mod" "$target_mod" "$backup_root" "$timestamp"
            fi
            log_info "  ✓ $mod_name already current (v$bundled_version)"
            continue
        fi

        case "$target_mod" in
            "$target_root"/*) ;;
            *)
                log_warn "  Refusing to update $mod_name because the target path is outside Mods"
                continue
                ;;
        esac

        mod_backup_root="$backup_root/$timestamp"
        mkdir -p "$mod_backup_root" || {
            log_warn "  Failed to prepare backup folder; leaving $mod_name untouched"
            continue
        }

        log_warn "  Updating bundled mod: $mod_name ${installed_version:-unknown} -> $bundled_version"
        cp -a "$target_mod" "$mod_backup_root/$mod_name" || {
            log_warn "  Failed to back up $mod_name; leaving installed copy untouched"
            continue
        }

        if [ "$mod_name" = "ServerAutoLoad" ] && server_autoload_config_is_legacy "$target_mod/config.json"; then
            preserve_config="false"
            log_warn "  ServerAutoLoad legacy config detected; v2 config will replace it"
        fi

        if [ "$preserve_config" = "true" ] && [ -f "$target_mod/config.json" ]; then
            config_backup="$mod_backup_root/$mod_name.config.json"
            cp -a "$target_mod/config.json" "$config_backup" 2>/dev/null || config_backup=""
        fi

        rm -rf "$target_mod"
        if cp -a "$source_mod" "$target_mod"; then
            if [ "$preserve_config" = "true" ] && [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
                cp -a "$config_backup" "$target_mod/config.json" 2>/dev/null || true
            fi
            log_info "  ✓ $mod_name updated; backup saved to $mod_backup_root/$mod_name"
        else
            log_warn "  Failed to copy bundled $mod_name; restoring backup"
            rm -rf "$target_mod"
            cp -a "$mod_backup_root/$mod_name" "$target_mod" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
}

configure_audio_driver() {
    if [ -n "${SDL_AUDIODRIVER:-}" ]; then
        :
    else
        export SDL_AUDIODRIVER=dummy
        log_info "No explicit audio driver configured; defaulting SDL_AUDIODRIVER=dummy"
        log_info "未显式配置音频驱动，默认使用 SDL_AUDIODRIVER=dummy"
    fi

    if [ -z "${ALSOFT_DRIVERS:-}" ]; then
        export ALSOFT_DRIVERS=null
        log_info "No explicit OpenAL driver configured; defaulting ALSOFT_DRIVERS=null"
        log_info "未显式配置 OpenAL 驱动，默认使用 ALSOFT_DRIVERS=null"
    fi
}

configure_performance_mode() {
    if [ "$LOW_PERF_MODE" != "true" ]; then
        return 0
    fi

    RESOLUTION_WIDTH=${LOW_PERF_RESOLUTION_WIDTH:-$LOW_PERF_DEFAULT_WIDTH}
    RESOLUTION_HEIGHT=${LOW_PERF_RESOLUTION_HEIGHT:-$LOW_PERF_DEFAULT_HEIGHT}

    if [ -z "$TARGET_FPS_RAW" ]; then
        TARGET_FPS=$LOW_PERF_DEFAULT_FPS
    fi
    REFRESH_RATE=${LOW_PERF_REFRESH_RATE:-$TARGET_FPS}
    XVFB_COLOR_DEPTH=${LOW_PERF_COLOR_DEPTH:-$LOW_PERF_DEFAULT_COLOR_DEPTH}

    export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-x11}
    export SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
    export MONO_GC_PARAMS=${MONO_GC_PARAMS:-nursery-size=8m}
    export DOTNET_GCHeapHardLimit=${DOTNET_GCHeapHardLimit:-0x30000000}

    if [ "${USE_GPU:-false}" != "true" ]; then
        export LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-1}
    fi

    XVFB_FB_DIR=${XVFB_FB_DIR:-/dev/shm/xvfb}
    if mkdir -p "$XVFB_FB_DIR" 2>/dev/null; then
        XVFB_FB_ARGS=(-fbdir "$XVFB_FB_DIR")
    else
        XVFB_FB_DIR=""
        XVFB_FB_ARGS=()
    fi

    log_info "Low performance mode enabled"
    log_info "低性能模式已启用"
    log_info "  Render target: ${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT} @ ${REFRESH_RATE}fps"
    log_info "  Xvfb color depth: ${XVFB_COLOR_DEPTH}bit"
    log_info "  SDL_VIDEODRIVER=${SDL_VIDEODRIVER}"
    log_info "  SDL_AUDIODRIVER=${SDL_AUDIODRIVER}"
    log_info "  MONO_GC_PARAMS=${MONO_GC_PARAMS}"
    log_info "  DOTNET_GCHeapHardLimit=${DOTNET_GCHeapHardLimit}"
    if [ -n "${LIBGL_ALWAYS_SOFTWARE:-}" ]; then
        log_info "  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
    fi
    if [ -n "$XVFB_FB_DIR" ]; then
        log_info "  Xvfb framebuffer directory: $XVFB_FB_DIR"
    fi
}

apply_startup_preferences_tuning() {
    local config_file=$1

    [ -f "$config_file" ] || return 0

    local player_limit="$MAX_PLAYERS"
    if ! echo "$player_limit" | grep -Eq '^[0-9]+$' || [ "$player_limit" -lt 1 ] || [ "$player_limit" -gt 8 ]; then
        player_limit=8
    fi

    perl -0pi -e "s#<playerLimit>.*?</playerLimit>#<playerLimit>${player_limit}</playerLimit>#s;
        s#<enableServer>.*?</enableServer>#<enableServer>true</enableServer>#s;
        s#<ipConnectionsEnabled>.*?</ipConnectionsEnabled>#<ipConnectionsEnabled>true</ipConnectionsEnabled>#s;
        s#<enableFarmhandCreation>.*?</enableFarmhandCreation>#<enableFarmhandCreation>true</enableFarmhandCreation>#s;" "$config_file"

    if [ "$LOW_PERF_MODE" != "true" ]; then
        return 0
    fi

    perl -0pi -e "s#<fullscreenResolutionX>.*?</fullscreenResolutionX>#<fullscreenResolutionX>${RESOLUTION_WIDTH}</fullscreenResolutionX>#s;
        s#<fullscreenResolutionY>.*?</fullscreenResolutionY>#<fullscreenResolutionY>${RESOLUTION_HEIGHT}</fullscreenResolutionY>#s;
        s#<preferredResolutionX>.*?</preferredResolutionX>#<preferredResolutionX>${RESOLUTION_WIDTH}</preferredResolutionX>#s;
        s#<preferredResolutionY>.*?</preferredResolutionY>#<preferredResolutionY>${RESOLUTION_HEIGHT}</preferredResolutionY>#s;
        s#<vsyncEnabled>.*?</vsyncEnabled>#<vsyncEnabled>true</vsyncEnabled>#s;
        s#<startMuted>.*?</startMuted>#<startMuted>true</startMuted>#s;
        s#<musicVolumeLevel>.*?</musicVolumeLevel>#<musicVolumeLevel>0</musicVolumeLevel>#s;
        s#<soundVolumeLevel>.*?</soundVolumeLevel>#<soundVolumeLevel>0</soundVolumeLevel>#s;" "$config_file"
}

# Function to download game via steamcmd
# 下载游戏函数
download_game_via_steam() {
    log_info "========================================="
    log_info "  Starting Steam download process"
    log_info "  开始 Steam 下载流程"
    log_info "========================================="
    log_info ""
    log_info "If Steam Guard is required, you will see a prompt."
    log_info "如果需要 Steam Guard，您会看到提示。"
    log_info ""
    log_info "To input Steam Guard code:"
    log_info "输入 Steam Guard 验证码："
    log_info "  1. You should already have run: docker attach puppy-stardew"
    log_info "  1. 您应该已经运行了：docker attach puppy-stardew"
    log_info "  2. Enter the code when prompted below"
    log_info "  2. 在下面提示时输入验证码"
    log_info "  3. Press ENTER"
    log_info "  3. 按回车"
    log_info ""
    log_info "After successful authentication, game will download (~708MB)"
    log_info "验证成功后，游戏将开始下载（约708MB）"
    log_info "========================================="
    log_info ""

    # Support STEAM_GUARD_CODE environment variable for easier auth
    # 支持 STEAM_GUARD_CODE 环境变量以简化验证
    STEAM_GUARD_ARGS=""
    if [ -n "$STEAM_GUARD_CODE" ]; then
        log_info "Using Steam Guard code from environment variable"
        log_info "使用环境变量中的 Steam Guard 验证码"
        STEAM_GUARD_ARGS="+set_steam_guard_code $STEAM_GUARD_CODE"
    fi

    # Run steamcmd WITHOUT pipe - this preserves stdin!
    # 运行 steamcmd 不使用管道 - 保留stdin！
    /home/steam/steamcmd/steamcmd.sh \
        +force_install_dir /home/steam/stardewvalley \
        $STEAM_GUARD_ARGS \
        +login "$STEAM_USERNAME" "$STEAM_PASSWORD" \
        +app_update 413150 validate \
        +quit

    DOWNLOAD_EXIT_CODE=$?

    # Check result
    if [ "$DOWNLOAD_EXIT_CODE" -eq 0 ] && [ -f "/home/steam/stardewvalley/StardewValley" ]; then
        log_info "✅ Game downloaded successfully!"
        log_info "✅ 游戏下载完成！"
        return 0
    else
        log_error "❌ Game download failed (exit code: $DOWNLOAD_EXIT_CODE)"
        log_error "❌ 游戏下载失败（退出码：$DOWNLOAD_EXIT_CODE）"
        log_error ""
        log_error "Common causes / 常见原因："
        log_error "  1. Steam Guard code incorrect / Steam Guard 验证码错误"
        log_error "  2. Network timeout / 网络超时"
        log_error "  3. Insufficient disk space / 磁盘空间不足"
        log_error "  4. Steam API rate limit / Steam API 速率限制"
        return 1
    fi
}

cleanup_nested_mod_folders() {
    local mods_root="/home/steam/stardewvalley/Mods"
    local backup_root="/home/steam/web-panel/data/mod-backups/nested-mods-$(date +%Y%m%d-%H%M%S)"

    [ -d "$mods_root" ] || return 0

    for nested_root in "$mods_root/Mods" "$mods_root/mods"; do
        [ -d "$nested_root" ] || continue

        log_warn "Detected nested Mods folder: $nested_root"
        log_warn "检测到嵌套 Mods 目录：$nested_root"
        mkdir -p "$backup_root"
        cp -a "$nested_root" "$backup_root/" 2>/dev/null || true

        while IFS= read -r manifest_file; do
            mod_dir="$(dirname "$manifest_file")"
            mod_name="$(basename "$mod_dir")"
            [ -n "$mod_name" ] || continue
            [ "$mod_name" = "Mods" ] && continue

            if [ ! -e "$mods_root/$mod_name" ]; then
                log_info "  Promoting nested mod: $mod_name"
                cp -a "$mod_dir" "$mods_root/$mod_name" 2>/dev/null || true
            fi
        done < <(find "$nested_root" -mindepth 1 -maxdepth 5 -name manifest.json -type f 2>/dev/null)

        rm -rf "$nested_root"
        log_warn "Removed nested Mods folder after backup: $backup_root"
        log_warn "已备份并删除嵌套 Mods 目录：$backup_root"
    done
}

# =============================================
# GPU-related helper function
# GPU 加速相关辅助函数
# =============================================
start_gpu_xorg() {
    local context=${1:-"unknown"}
    if [ "$USE_GPU" != "true" ]; then
        log_warn "USE_GPU != true, skipping GPU startup (context: $context)"
        log_warn "USE_GPU != true，跳过 GPU 启动逻辑（context: $context）"
        return 3
    fi

    log_info "USE_GPU=true -> Attempting to start Xorg :99 for GPU rendering (context: $context)"
    log_info "USE_GPU=true -> 在 ${context} 阶段尝试启动 Xorg :99 以使用 GPU 渲染"
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true

    if [ -e /dev/dri/renderD128 ] || ls /dev/dri 2>/dev/null | grep -q .; then
        log_info "Detected /dev/dri, starting Xorg :99 (context: $context)"
        log_info "检测到 /dev/dri，准备启动 Xorg :99 (context: $context)"

        # Ensure X socket directory exists with correct permissions
        mkdir -p /tmp/.X11-unix
        chmod 1777 /tmp/.X11-unix

        # Ensure Xorg log directory exists
        mkdir -p /home/steam/.local/share/xorg
        if [ "$(id -u)" = "0" ]; then
            chown root:root /home/steam/.local/share/xorg 2>/dev/null || true
        fi

        # Start Xorg in background
        Xorg -noreset +extension GLX +extension RANDR :99 -logfile /home/steam/.local/share/xorg/Xorg.0.log &
        sleep 2

        # Set resolution via set-resolution.sh
        DISPLAY=:99 /home/steam/scripts/set-resolution.sh "${RESOLUTION_WIDTH}" "${RESOLUTION_HEIGHT}" "${REFRESH_RATE}" || {
            log_warn "Failed to set resolution (context: $context), continuing with default"
            log_warn "设置分辨率失败（context: $context），将继续使用默认分辨率"
        }
        sleep 1

        if pgrep -x Xorg >/dev/null 2>&1; then
            export DISPLAY=${DISPLAY:-:99}
            log_info "✓ Xorg started on :99 (context: $context)"
            log_info "✓ Xorg 已在 :99 启动（context: $context）"
            if command -v glxinfo >/dev/null 2>&1; then
                log_info "OpenGL renderer:"
                glxinfo | grep -i "OpenGL renderer" | head -n 1 || true
            fi
            return 0
        else
            log_warn "Xorg failed to start (context: $context)"
            log_warn "Xorg 未能在 ${context} 阶段启动"
            return 2
        fi
    else
        log_warn "/dev/dri not detected, skipping Xorg startup (context: $context)"
        log_warn "/dev/dri 未检测到或不可访问，跳过 Xorg 启动（context: $context）"
        return 1
    fi
}

# =============================================
# Phase 1: Root Initialization
# 阶段1：Root 初始化
#
# Permission fixes are handled by the init container (init-container.sh).
# This phase only handles GPU Xorg startup (requires root) and user switch.
# 权限修复由初始化容器 (init-container.sh) 处理。
# 此阶段仅处理 GPU Xorg 启动（需要 root）和用户切换。
# =============================================

configure_audio_driver
configure_performance_mode

if [ "$(id -u)" = "0" ]; then
    log_step "================================================"
    log_step "  Phase 1: Root Initialization"
    log_step "  阶段1：Root 初始化"
    log_step "================================================"

    # Fix libcurl compatibility for SteamCMD (idempotent, fast)
    if [ ! -e "/usr/lib/x86_64-linux-gnu/libcurl.so.4" ]; then
        ln -sf /usr/lib/i386-linux-gnu/libcurl.so.4 /usr/lib/x86_64-linux-gnu/libcurl.so.4
        log_info "✅ libcurl symlink created"
    fi

    # Try to start Xorg in root phase if USE_GPU=true
    # Xorg requires root privileges to access /dev/dri
    if [ "$USE_GPU" = "true" ]; then
        start_gpu_xorg "root" || {
            log_warn "GPU startup in root phase unsuccessful, will fallback to Xvfb"
        }
    fi

    mkdir -p /home/steam/.local/share/puppy-stardew \
             /home/steam/.local/share/puppy-stardew/logs \
             /home/steam/.local/share/puppy-stardew/backups \
             /home/steam/web-panel/data \
             "$PUPPY_META_DIR"
    chown -R 1000:1000 /home/steam/.local/share/puppy-stardew /home/steam/web-panel/data 2>/dev/null || true
    write_orchestration_state "INIT" "root_initialization" "Root phase completed; switching to steam user."

    log_info "Switching to steam user..."

    # Re-execute this script as steam user
    exec runuser -u steam -- env DISPLAY="$DISPLAY" "$0" "$@"
fi

# =============================================
# Phase 2: Steam User Operations
# 阶段2：Steam 用户操作
# =============================================

log_step "================================================"
log_step "  Puppy Stardew Server v1.1.0 Starting..."
log_step "  小狗星谷服务器 v1.1.0 启动中..."
log_step "================================================"

# Verify we're running as steam user
if [ "$(id -u)" != "1000" ]; then
    log_error "ERROR: Script must run as steam user (UID 1000)"
    log_error "错误：脚本必须以 steam 用户（UID 1000）运行"
    exit 1
fi

# Step 1: Validate Steam credentials (supports Docker Secrets)
# 步骤 1：验证 Steam 凭证（支持 Docker Secrets）
log_step "Step 1: Validating configuration..."

# Docker Secrets support: read from /run/secrets/ if env vars are empty
# Docker Secrets 支持：如果环境变量为空，从 /run/secrets/ 读取
write_orchestration_state "VERIFYING" "steam_credentials" "Validating Steam credentials and secret sources."

if { [ -z "$STEAM_USERNAME" ] || [ -z "$STEAM_PASSWORD" ]; } && [ -f "$STEAM_JSON_SECRET" ]; then
    parsed_secret=$(node -e '
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const username = data.username || data.STEAM_USERNAME || data.steamUsername || "";
  const password = data.password || data.STEAM_PASSWORD || data.steamPassword || "";
  if (username) console.log(`STEAM_USERNAME=${username}`);
  if (password) console.log(`STEAM_PASSWORD=${password}`);
} catch (error) {
  process.exit(2);
}
' "$STEAM_JSON_SECRET" 2>/dev/null || true)
    while IFS='=' read -r key value; do
        case "$key" in
            STEAM_USERNAME)
                [ -z "$STEAM_USERNAME" ] && STEAM_USERNAME="$value"
                ;;
            STEAM_PASSWORD)
                [ -z "$STEAM_PASSWORD" ] && STEAM_PASSWORD="$value"
                ;;
        esac
    done <<EOF
$parsed_secret
EOF
    if [ -n "$parsed_secret" ]; then
        log_info "Steam credentials loaded from JSON secret"
    fi
fi

if [ -z "$STEAM_USERNAME" ] && [ -f "/run/secrets/steam_username" ]; then
    STEAM_USERNAME=$(cat /run/secrets/steam_username | tr -d '\n')
    log_info "Steam username loaded from Docker Secret"
fi
if [ -z "$STEAM_PASSWORD" ] && [ -f "/run/secrets/steam_password" ]; then
    STEAM_PASSWORD=$(cat /run/secrets/steam_password | tr -d '\n')
    log_info "Steam password loaded from Docker Secret"
fi

if [ -z "$STEAM_USERNAME" ] || [ -z "$STEAM_PASSWORD" ]; then
    log_error "STEAM_USERNAME or STEAM_PASSWORD not set!"
    log_error "STEAM_USERNAME 或 STEAM_PASSWORD 未设置！"
    log_error "Set via .env file or Docker Secrets."
    log_error "通过 .env 文件或 Docker Secrets 设置。"
    fail_startup "steam_credentials_missing" "Steam credentials are missing. Set .env, Docker Secrets or /home/steam/secrets/steam.json." 1
fi

log_info "Steam credentials configured"

force_game_update=false
if [ "${STEAM_UPDATE_ON_START}" = "true" ] || [ -f "$FORCE_STEAM_UPDATE_MARKER" ]; then
    force_game_update=true
fi

# Step 2: Download or validate game if needed
if [ ! -f "/home/steam/stardewvalley/StardewValley" ] || [ "$force_game_update" = "true" ]; then
    write_orchestration_state "LOADING" "game_download" "Stardew Valley files are missing; downloading through SteamCMD."
    if [ "$force_game_update" = "true" ]; then
        write_orchestration_state "LOADING" "game_update" "Forcing SteamCMD app_update 413150 validate before launch."
        log_step "Step 2: Validating Stardew Valley through Steam..."
        log_warn "Force game update marker detected. SteamCMD will validate and update Stardew Valley."
        log_warn "检测到强制游戏更新标记，SteamCMD 将校验并更新星露谷本体。"
    else
        log_step "Step 2: Downloading Stardew Valley..."
        log_warn "Game files not found. Downloading from Steam..."
        log_warn "未找到游戏文件。正在从 Steam 下载..."
        log_warn "This will take 5-10 minutes depending on your connection."
        log_warn "根据网络情况，此过程需要 5-10 分钟。"
    fi
    log_warn ""

    if [ "$force_game_update" != "true" ]; then
        # Clean up any existing Steam cache only on first install. Keeping it on
        # update avoids unnecessary Steam Guard prompts for existing servers.
        log_info "Cleaning Steam cache..."
        rm -rf /home/steam/Steam/config/* 2>/dev/null || true
        rm -rf /home/steam/Steam/logs/* 2>/dev/null || true
        rm -rf /tmp/steam* 2>/dev/null || true
    fi

    # Download game (handles Steam Guard automatically)
    if ! download_game_via_steam; then
        log_error "Failed to download game. Container will exit."
        log_error "游戏下载失败。容器将退出。"
        fail_startup "game_download_failed" "Stardew Valley download failed. Check Steam Guard, Steam credentials, network and disk space." 1
    fi
    rm -f "$FORCE_STEAM_UPDATE_MARKER" 2>/dev/null || true
else
    write_orchestration_state "VERIFYING" "game_files_present" "Stardew Valley files found."
    log_step "Step 2: Game files found, skipping download"
    log_info "✓ Stardew Valley already downloaded"
    log_info "✓ 星露谷物语已下载"
fi

# Step 3: Install SMAPI
log_step "Step 3: Installing SMAPI mod loader..."
write_orchestration_state "VERIFYING" "smapi_install" "Checking SMAPI installation."

log_info "Installing bundled SMAPI to avoid stale persistent game files..."
cd /home/steam
echo "1" | dotnet smapi/SMAPI*/internal/linux/SMAPI.Installer.dll --install --game-path /home/steam/stardewvalley

if [ $? -ne 0 ]; then
    log_error "Failed to install SMAPI!"
    log_error "SMAPI 安装失败！"
    fail_startup "smapi_install_failed" "SMAPI installation failed. Check the downloaded game files and bundled SMAPI installer." 1
else
    bundled_smapi_version="$(cat /home/steam/smapi-version.txt 2>/dev/null || echo unknown)"
    log_info "✓ SMAPI installed/updated successfully (bundled $bundled_smapi_version)"
fi

# Step 4: Install mods
log_step "Step 4: Installing mods..."
write_orchestration_state "VERIFYING" "mod_install" "Synchronizing bundled and custom mods."

mkdir -p /home/steam/stardewvalley/Mods

if [ -d "/home/steam/preinstalled-mods" ]; then
    sync_preinstalled_mods

    log_info "Installed mods:"
    ls -1 /home/steam/stardewvalley/Mods/ | while read mod; do
        log_info "  ✓ $mod"
    done
fi

cleanup_nested_mod_folders

# Step 4.5: Install user-provided mods from custom-mods volume
# 步骤 4.5：从 custom-mods 卷安装用户提供的模组
CUSTOM_MODS_DIR="/home/steam/custom-mods"
if [ -d "$CUSTOM_MODS_DIR" ] && [ "$(ls -A "$CUSTOM_MODS_DIR" 2>/dev/null)" ]; then
    log_step "Step 4.5: Installing custom mods..."
    log_info "Found custom mods in $CUSTOM_MODS_DIR"

    for mod_entry in "$CUSTOM_MODS_DIR"/*; do
        mod_name=$(basename "$mod_entry")

        # Skip hidden files
        [[ "$mod_name" == .* ]] && continue

        if [ -d "$mod_entry" ]; then
            # It's a mod directory - copy to Mods/
            log_info "  Installing mod: $mod_name"
            cp -r "$mod_entry" "/home/steam/stardewvalley/Mods/$mod_name"
        elif [[ "$mod_entry" == *.zip ]]; then
            metadata_file="${mod_entry%.zip}.panel-meta.json"
            if [ -f "$metadata_file" ]; then
                log_info "  Skipping managed archive already installed by panel: $mod_name"
                continue
            fi

            # It's a zip file - extract to Mods/
            log_info "  Extracting mod: $mod_name"
            unzip -q -o "$mod_entry" -d "/home/steam/stardewvalley/Mods/" 2>/dev/null || {
                log_warn "  ⚠ Failed to extract: $mod_name"
            }
        fi
    done
    cleanup_nested_mod_folders
    log_info "✓ Custom mods installed"
fi

# Step 5: Setup virtual display
log_step "Step 5: Starting virtual display..."
write_orchestration_state "STABILIZING" "display_start" "Starting virtual display."

# Check if Xorg is already running from root phase
START_XVFB_FALLBACK=false

if pgrep -x Xorg >/dev/null 2>&1; then
    export DISPLAY=${DISPLAY:-:99}
    log_info "Detected Xorg process, using DISPLAY=${DISPLAY}"
    log_info "检测到 Xorg 进程，使用 DISPLAY=${DISPLAY}"
    if command -v glxinfo >/dev/null 2>&1; then
        log_info "OpenGL renderer:"
        glxinfo | grep -i "OpenGL renderer" | head -n 1 || true
    fi
else
    # Fallback to Xvfb if GPU not enabled or failed
    if [ "$USE_GPU" = "true" ]; then
        log_warn "Xorg not running in steam phase, falling back to Xvfb"
        log_warn "steam 阶段 Xorg 未运行，回退到 Xvfb（软件渲染）"
    fi
    START_XVFB_FALLBACK=true
fi

# Start Xvfb as fallback
if [ "$START_XVFB_FALLBACK" = "true" ]; then
    log_info "Starting Xvfb (software rendering fallback)..."
    log_info "启动 Xvfb（软件渲染后备）..."
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
    Xvfb :99 -screen 0 "${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH}" -ac +extension GLX +render -noreset "${XVFB_FB_ARGS[@]}" &
    export DISPLAY=${DISPLAY:-:99}
    sleep 3
    log_info "✓ Virtual display started on ${DISPLAY} (${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH})"
    log_info "✓ 虚拟显示已启动 ${DISPLAY} (${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH})"
fi

# Step 6: Start VNC server (optional)
if [ "$ENABLE_VNC" = "true" ]; then
    log_step "Step 6: Starting VNC server..."

    # Do not ship a weak well-known default. If no password is provided, generate
    # a random one at runtime and persist it to a protected file for the operator.
    VNC_PASSWORD_FILE="/home/steam/web-panel/data/vnc_password.txt"
    VNC_PASSWORD_GENERATED=false
    if [ -z "$VNC_PASSWORD" ]; then
        VNC_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)
        VNC_PASSWORD_GENERATED=true
    fi

    if [ ${#VNC_PASSWORD} -gt 8 ]; then
        log_warn "VNC password > 8 chars, truncating to 8 characters (x11vnc limit)"
        VNC_PASSWORD="${VNC_PASSWORD:0:8}"
    fi

    # Persist the effective password to a 0600 file so the monitor and operator
    # can read it without printing the secret to container logs.
    export VNC_PASSWORD
    mkdir -p "$(dirname "$VNC_PASSWORD_FILE")" 2>/dev/null || true
    if printf '%s' "$VNC_PASSWORD" > "$VNC_PASSWORD_FILE" 2>/dev/null; then
        chmod 600 "$VNC_PASSWORD_FILE" 2>/dev/null || true
    fi

    # Wait for X server to be fully ready
    sleep 2

    # Start x11vnc pointing to current DISPLAY
    log_info "Starting x11vnc on display ${DISPLAY} (port 5900)..."
    x11vnc -display "${DISPLAY}" -forever -shared -passwd "$VNC_PASSWORD" -rfbport 5900 -noxdamage -bg 2>&1 | grep -v "^$"

    # Wait for x11vnc to start
    sleep 2

    # Verify VNC is running
    if pgrep -x "x11vnc" >/dev/null; then
        log_info "✓ VNC server started successfully on port 5900"
        if [ "$VNC_PASSWORD_GENERATED" = "true" ]; then
            log_info "  A random VNC password was generated (VNC_PASSWORD was not set)."
        fi
        log_info "  Password stored at: $VNC_PASSWORD_FILE (not printed to logs)"
        log_info "  Retrieve it with: docker exec <container> cat $VNC_PASSWORD_FILE"
        log_info "  Connect to: your-server-ip:5900"

        # Start VNC monitor to keep it alive
        # 启动 VNC 监控，保持服务存活
        if [ -f "/home/steam/scripts/vnc-monitor.sh" ]; then
            log_info "Starting VNC health monitor..."
            /home/steam/scripts/vnc-monitor.sh &
            log_info "✓ VNC monitor started (30s check interval)"
        fi
    else
        log_error "✗ VNC server failed to start"
        log_error "Check logs above for errors"
    fi
else
    log_step "Step 6: VNC disabled (set ENABLE_VNC=true to enable)"
fi

# Step 7: Setup optimized game config for VNC display
log_step "Step 7: Configuring game display settings..."

CONFIG_DIR="/home/steam/.config/StardewValley"
CONFIG_FILE="$CONFIG_DIR/startup_preferences"
TEMPLATE="/home/steam/startup_preferences.template"

# Create config directory if not exists
mkdir -p "$CONFIG_DIR"

# Copy optimized config template if startup_preferences doesn't exist yet
# 如果startup_preferences还不存在，复制优化的配置模板
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "$TEMPLATE" ]; then
        cp "$TEMPLATE" "$CONFIG_FILE"
        log_info "✓ Applied optimized display config (fullscreen mode for VNC)"
        log_info "✓ 已应用优化的显示配置（VNC全屏模式）"
    else
        log_warn "⚠ Template not found, game will use default settings"
    fi
else
    log_info "✓ Game config already exists, keeping user settings"
fi

apply_startup_preferences_tuning "$CONFIG_FILE"
if [ "$LOW_PERF_MODE" = "true" ]; then
    log_info "✓ Applied low performance startup preferences"
    log_info "✓ 已应用低性能启动偏好设置"
fi

# Step 7.5: Select save if specified
if [ -n "$SAVE_NAME" ]; then
    log_step "Step 7.5: Selecting save file..."
    /home/steam/scripts/save-selector.sh
fi

# Step 8: Start log monitoring (optional)
if [ "$ENABLE_LOG_MONITOR" = "true" ]; then
    log_step "Step 8: Starting log monitoring..."
    write_orchestration_state "STABILIZING" "log_monitor" "Starting log monitor."

    if [ -f "/home/steam/scripts/log-monitor.sh" ]; then
        /home/steam/scripts/log-monitor.sh &
        log_info "✓ Log monitoring started"
    fi
else
    log_step "Step 8: Log monitoring disabled"
fi

# Step 9: Start game server
log_step "Step 9: Starting game server..."
write_orchestration_state "STABILIZING" "game_launch" "Launching StardewModdingAPI host process."
log_info "================================================"
log_info "  Server is starting!"
log_info "  服务器启动中！"
log_info "================================================"
log_info ""
log_info "Save setup options:"
log_info "存档初始化方式："
log_info "  1. Web panel: http://localhost:18642 (set admin password on first visit)"
log_info "  1. Web 面板：http://localhost:18642（首次访问先设置管理密码）"
log_info "  2. Upload an existing save in the panel and set it as the default auto-load save"
log_info "  2. 在面板上传现有存档，并设为默认自动加载存档"
log_info "  3. Optional: use VNC only if you want to create a new save manually in-game"
log_info "  3. 可选：只有想手动进游戏创建新存档时才使用 VNC"
log_info ""
log_info "Players connect via:"
log_info "玩家连接方式："
log_info "  1. Open Stardew Valley → CO-OP → Join LAN Game"
log_info "  1. 打开星露谷物语 → CO-OP → 加入局域网游戏"
log_info "  2. Server will appear automatically, or enter server IP directly"
log_info "  2. 服务器会自动出现，或直接输入服务器IP"
log_info "  3. No port number needed (default: 24642/UDP)"
log_info "  3. 无需输入端口号（默认：24642/UDP）"
log_info "================================================"
log_info ""

cd /home/steam/stardewvalley

# Start unified event handler in background
log_info "Starting unified event handler..."
/home/steam/scripts/event-handler.sh &

# Start auto-backup if enabled
if [ "$ENABLE_AUTO_BACKUP" = "true" ]; then
    log_info "Starting auto-backup service..."
    /home/steam/scripts/auto-backup.sh &
fi

# Start status reporter (Prometheus metrics + JSON status)
log_info "Starting status reporter (metrics port: ${METRICS_PORT:-9090})..."
/home/steam/scripts/status-reporter.sh &

# Start web panel
log_info "Starting web management panel (port: 18642)..."
cd /home/steam/web-panel
node server.js &
WEB_PANEL_PID=$!
log_info "✓ Web panel started (PID: $WEB_PANEL_PID)"
log_info "  Access at: http://localhost:18642"
cd /home/steam/stardewvalley

# Start player access control if configured
if [ -f "/home/steam/.config/StardewValley/player-access.conf" ]; then
    log_info "Starting player access control..."
    /home/steam/scripts/player-access.sh &
fi

# Start crash monitor if enabled
if [ "$ENABLE_CRASH_RESTART" = "true" ]; then
    log_info "Starting game with crash auto-restart..."
    log_info "启动游戏（崩溃自动重启模式）..."

    # Use crash-monitor.sh which wraps game in restart loop
    exec /home/steam/scripts/crash-monitor.sh
else
    # Run game with exec (traditional, container exits on crash)
    exec ./StardewModdingAPI --server
fi
