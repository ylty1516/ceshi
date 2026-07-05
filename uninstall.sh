#!/usr/bin/env sh
set -eu

info() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_script_dir() {
  case "$0" in
    */*) script_path="$0" ;;
    *) script_path="./$0" ;;
  esac

  case "$script_path" in
    /*) script_dir=$(dirname "$script_path") ;;
    *) script_dir=$(dirname "$(pwd -P)/$script_path") ;;
  esac

  cd "$script_dir" 2>/dev/null && pwd -P
}

SCRIPT_DIR=$(resolve_script_dir)
PROJECT_DIR=${PUPPY_PROJECT_DIR:-$SCRIPT_DIR}
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || fail "Project directory does not exist: $PROJECT_DIR"
COMPOSE_FILE=${PUPPY_COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}
KEEP_FILES=${PUPPY_UNINSTALL_KEEP_FILES:-false}
CONFIRM=${PUPPY_UNINSTALL_CONFIRM:-}

validate_project_dir() {
  [ -n "$PROJECT_DIR" ] || fail "PROJECT_DIR is empty."
  [ "$PROJECT_DIR" != "/" ] || fail "Refusing to uninstall root directory."

  case "$PROJECT_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      fail "Refusing to uninstall broad system directory: $PROJECT_DIR"
      ;;
  esac

  [ -d "$PROJECT_DIR" ] || fail "Project directory does not exist: $PROJECT_DIR"
  [ -f "$COMPOSE_FILE" ] || fail "Compose file does not exist: $COMPOSE_FILE"
  [ -f "$PROJECT_DIR/docker-compose.yml" ] || fail "Missing docker-compose.yml marker in project directory."
  [ -f "$PROJECT_DIR/docker/web-panel/server.js" ] || fail "Missing web panel marker in project directory."
  [ -f "$PROJECT_DIR/docker/manager/server.js" ] || fail "Missing manager marker in project directory."

  if ! grep -q 'puppy-stardew' "$PROJECT_DIR/docker-compose.yml"; then
    fail "docker-compose.yml does not look like the Puppy Stardew project."
  fi
}

confirm_uninstall() {
  if [ "$CONFIRM" = "UNINSTALL" ]; then
    return
  fi

  info "This will uninstall only this Stardew co-op project:"
  info "  $PROJECT_DIR"
  info "It will remove project containers, local project images, and the project folder."
  info "Docker itself and other server projects will NOT be removed."
  info ""

  if [ ! -t 0 ]; then
    fail "Non-interactive uninstall requires PUPPY_UNINSTALL_CONFIRM=UNINSTALL."
  fi

  printf 'Type UNINSTALL to continue: '
  read -r typed || true
  [ "${typed:-}" = "UNINSTALL" ] || fail "Confirmation mismatch. Uninstall cancelled."
}

compose_down() {
  if ! command -v docker >/dev/null 2>&1; then
    info "Docker command not found. Skipping container cleanup and removing project files only."
    return
  fi

  if ! docker info >/dev/null 2>&1; then
    fail "Docker is installed but not reachable. Refusing to delete project files while containers may still be running."
  fi

  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" --project-directory "$PROJECT_DIR" down --remove-orphans || true
  elif command -v docker-compose >/dev/null 2>&1; then
    (cd "$PROJECT_DIR" && docker-compose -f "$COMPOSE_FILE" down --remove-orphans) || true
  else
    info "Docker Compose is not available. Removing known project containers directly."
  fi

  for name in \
    puppy-stardew \
    puppy-stardew-init \
    puppy-stardew-manager \
    puppy-stardew-panel-updater \
    puppy-stardew-factory-reset \
    puppy-stardew-uninstaller
  do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done

  docker image rm -f puppy-stardew-server:local puppy-stardew-manager:local >/dev/null 2>&1 || true
}

validate_project_dir
confirm_uninstall

info "Stopping and removing this project's Docker resources..."
compose_down

if [ "$KEEP_FILES" = "true" ]; then
  info "PUPPY_UNINSTALL_KEEP_FILES=true, project files were kept at: $PROJECT_DIR"
  exit 0
fi

info "Deleting project directory: $PROJECT_DIR"
cd /
rm -rf -- "$PROJECT_DIR"
[ ! -e "$PROJECT_DIR" ] || fail "Project directory still exists after removal attempt: $PROJECT_DIR"
info "Uninstall finished. Docker itself and other server projects were not changed."
