#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$REPOSITORY_ROOT/assets/brand/skep-icon.svg"
MACOS_RESOURCES="$REPOSITORY_ROOT/apps/macos/Resources"
WEB_RESOURCES="$REPOSITORY_ROOT/website/public"
WORK_ROOT=$(mktemp -d -t skep-icon)
MASTER="$WORK_ROOT/skep-icon-1024.png"
ICONSET="$WORK_ROOT/Skep.iconset"

cleanup() { rm -rf "$WORK_ROOT"; }
trap cleanup EXIT HUP INT TERM

test -f "$SOURCE"
install -d -m 0755 "$ICONSET" "$MACOS_RESOURCES" "$WEB_RESOURCES"
sips -s format png "$SOURCE" --out "$MASTER" >/dev/null

make_png() {
  size=$1
  destination=$2
  sips -z "$size" "$size" "$MASTER" --out "$destination" >/dev/null
}

make_png 16 "$ICONSET/icon_16x16.png"
make_png 32 "$ICONSET/icon_16x16@2x.png"
make_png 32 "$ICONSET/icon_32x32.png"
make_png 64 "$ICONSET/icon_32x32@2x.png"
make_png 128 "$ICONSET/icon_128x128.png"
make_png 256 "$ICONSET/icon_128x128@2x.png"
make_png 256 "$ICONSET/icon_256x256.png"
make_png 512 "$ICONSET/icon_256x256@2x.png"
make_png 512 "$ICONSET/icon_512x512.png"
install -m 0644 "$MASTER" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$MACOS_RESOURCES/Skep.icns"

install -m 0644 "$SOURCE" "$WEB_RESOURCES/favicon.svg"
make_png 16 "$WEB_RESOURCES/favicon-16x16.png"
make_png 32 "$WEB_RESOURCES/favicon-32x32.png"
make_png 180 "$WEB_RESOURCES/apple-touch-icon.png"
make_png 192 "$WEB_RESOURCES/icon-192.png"
make_png 512 "$WEB_RESOURCES/icon-512.png"
sips -s format ico "$WEB_RESOURCES/favicon-32x32.png" \
  --out "$WEB_RESOURCES/favicon.ico" >/dev/null

echo "Built Skep app and web icon assets"
