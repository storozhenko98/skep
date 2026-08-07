#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RELEASE_ROOT="$REPOSITORY_ROOT/target/release"
PAYLOAD_ROOT="$REPOSITORY_ROOT/artifacts/local-host-installer"

command -v cargo >/dev/null 2>&1 || {
  echo "Rust is required to build the Skep local helper payload." >&2
  exit 1
}

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ;;
  *)
    echo "The local Skep runtime currently requires macOS on Apple Silicon." >&2
    exit 1
    ;;
esac

(
  cd "$REPOSITORY_ROOT"
  cargo build --workspace --release
)

rm -rf "$PAYLOAD_ROOT"
install -d -m 0755 "$PAYLOAD_ROOT"
install -m 0755 "$RELEASE_ROOT/skepd" "$RELEASE_ROOT/skepctl" "$PAYLOAD_ROOT/"

(
  cd "$PAYLOAD_ROOT"
  LC_ALL=C LANG=C shasum -a 256 skepd skepctl >SHA256SUMS
)

echo "Built local host payload at $PAYLOAD_ROOT"
