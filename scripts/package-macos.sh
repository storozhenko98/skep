#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MACOS_ROOT="$REPOSITORY_ROOT/apps/macos"
APP_ROOT="$REPOSITORY_ROOT/artifacts/Skep.app"
CONTENTS="$APP_ROOT/Contents"

if [ ! -d "$MACOS_ROOT/Frameworks/GhosttyKit.xcframework" ]; then
  "$SCRIPT_DIR/build-ghostty-framework.sh"
fi

"$SCRIPT_DIR/build-linux-host-payload.sh"
"$SCRIPT_DIR/build-local-host-payload.sh"

(
  cd "$MACOS_ROOT"
  swift test
  swift build -c release
)

rm -rf "$APP_ROOT"
install -d -m 0755 "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 0755 "$MACOS_ROOT/.build/arm64-apple-macosx/release/Skep" "$CONTENTS/MacOS/Skep"
install -m 0644 "$MACOS_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 0644 "$REPOSITORY_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
ditto "$REPOSITORY_ROOT/artifacts/host-installer" "$CONTENTS/Resources/HostInstaller"
ditto "$REPOSITORY_ROOT/artifacts/local-host-installer" "$CONTENTS/Resources/LocalHostInstaller"
codesign --force --deep --sign - "$APP_ROOT"
codesign --verify --deep --strict "$APP_ROOT"

echo "Packaged $APP_ROOT"
