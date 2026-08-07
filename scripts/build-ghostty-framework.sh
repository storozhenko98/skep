#!/bin/sh
set -eu

GHOSTTY_REPOSITORY=https://github.com/ghostty-org/ghostty.git
GHOSTTY_REVISION=f9b2ad8dbed93e0b8cdd6320d8f5a46ba15c5bc8

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR="$REPOSITORY_ROOT/apps/macos/.build/ghostty-source"
FRAMEWORK_DESTINATION="$REPOSITORY_ROOT/apps/macos/Frameworks/GhosttyKit.xcframework"

command -v zig >/dev/null 2>&1 || {
  echo "Zig 0.16 or newer is required to build GhosttyKit." >&2
  exit 1
}

if [ ! -d "$SOURCE_DIR/.git" ]; then
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git init -q "$SOURCE_DIR"
  git -C "$SOURCE_DIR" remote add origin "$GHOSTTY_REPOSITORY"
fi

if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)" != "$GHOSTTY_REVISION" ]; then
  git -C "$SOURCE_DIR" fetch --depth 1 origin "$GHOSTTY_REVISION"
  git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
fi

(
  cd "$SOURCE_DIR"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native
)

rm -rf "$FRAMEWORK_DESTINATION"
mkdir -p "$(dirname "$FRAMEWORK_DESTINATION")"
ditto "$SOURCE_DIR/macos/GhosttyKit.xcframework" "$FRAMEWORK_DESTINATION"
echo "Built $FRAMEWORK_DESTINATION at Ghostty $GHOSTTY_REVISION"
