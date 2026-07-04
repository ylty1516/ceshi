#!/usr/bin/env bash
# Build release archives from tracked repository files only.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-"$ROOT_DIR/dist"}"
PACKAGE_NAME="${PUPPY_RELEASE_PACKAGE_NAME:-puppy-stardew-server-updated}"

mkdir -p "$OUT_DIR"

git -C "$ROOT_DIR" archive \
  --format=tar.gz \
  --prefix="$PACKAGE_NAME/" \
  -o "$OUT_DIR/$PACKAGE_NAME.tar.gz" \
  HEAD

git -C "$ROOT_DIR" archive \
  --format=zip \
  --prefix="$PACKAGE_NAME/" \
  -o "$OUT_DIR/$PACKAGE_NAME.zip" \
  HEAD

if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "$OUT_DIR"
    sha256sum "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME.zip" > SHA256SUMS.txt
  )
fi

printf 'Release archives written to %s\n' "$OUT_DIR"
