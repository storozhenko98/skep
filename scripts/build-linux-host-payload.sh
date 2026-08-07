#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TARGET=x86_64-unknown-linux-gnu
RELEASE_ROOT="$REPOSITORY_ROOT/target/$TARGET/release"
PAYLOAD_ROOT="$REPOSITORY_ROOT/artifacts/host-installer"
LINKER="$SCRIPT_DIR/x86_64-linux-gnu-zig-cc.sh"

command -v cargo >/dev/null 2>&1 || {
  echo "Rust is required to build the Skep Linux host payload." >&2
  exit 1
}
command -v zig >/dev/null 2>&1 || {
  echo "Zig is required to cross-compile the Skep Linux host payload." >&2
  exit 1
}
rustup target list --installed | grep -qx "$TARGET" || {
  echo "Install the Rust target with: rustup target add $TARGET" >&2
  exit 1
}

(
  cd "$REPOSITORY_ROOT"
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$LINKER" \
    cargo build --workspace --release --target "$TARGET"
)

rm -rf "$PAYLOAD_ROOT"
install -d -m 0755 "$PAYLOAD_ROOT"
install -m 0755 "$RELEASE_ROOT/skepd" "$RELEASE_ROOT/skepctl" "$PAYLOAD_ROOT/"
install -m 0644 "$REPOSITORY_ROOT/deploy/systemd/skepd.service" "$PAYLOAD_ROOT/"
install -m 0755 \
  "$REPOSITORY_ROOT/deploy/install.sh" \
  "$REPOSITORY_ROOT/deploy/install-microsandbox.sh" \
  "$REPOSITORY_ROOT/deploy/uninstall.sh" \
  "$PAYLOAD_ROOT/"

(
  cd "$PAYLOAD_ROOT"
  LC_ALL=C LANG=C shasum -a 256 \
    skepd \
    skepctl \
    skepd.service \
    install.sh \
    install-microsandbox.sh \
    uninstall.sh >SHA256SUMS
)

echo "Built Linux host payload at $PAYLOAD_ROOT"
