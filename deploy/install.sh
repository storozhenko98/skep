#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must run as root" >&2
  exit 1
fi

SOURCE_DIR=${1:-.}
OPERATOR=${SKEP_OPERATOR:-${SUDO_USER:-}}

command -v visudo >/dev/null 2>&1 || {
  echo "sudo/visudo is required for the Skep SSH privilege boundary" >&2
  exit 1
}

if ! getent group skep >/dev/null 2>&1; then
  groupadd --system skep
fi
if [ -n "$OPERATOR" ] && [ "$OPERATOR" != root ]; then
  if ! id "$OPERATOR" >/dev/null 2>&1; then
    echo "SKEP_OPERATOR does not name an existing user: $OPERATOR" >&2
    exit 1
  fi
  usermod -aG skep "$OPERATOR"
fi

install -m 0755 "$SOURCE_DIR/skepd" /usr/local/bin/skepd
install -m 0755 "$SOURCE_DIR/skepctl" /usr/local/bin/skepctl
install -m 0644 "$SOURCE_DIR/skepd.service" /etc/systemd/system/skepd.service
SUDOERS_TEMP=$(mktemp /etc/sudoers.d/skep.XXXXXX)
trap 'rm -f "$SUDOERS_TEMP"' EXIT HUP INT TERM
cat >"$SUDOERS_TEMP" <<'EOF'
%skep ALL=(root) NOPASSWD: /usr/local/bin/skepctl bridge
%skep ALL=(root) NOPASSWD: /usr/local/bin/skepctl workspace-shell *
EOF
chmod 0440 "$SUDOERS_TEMP"
visudo -cf "$SUDOERS_TEMP" >/dev/null
mv "$SUDOERS_TEMP" /etc/sudoers.d/skep
trap - EXIT HUP INT TERM
install -d -m 0750 /var/lib/skep /var/lib/skep/exports /run/skep
systemctl daemon-reload
systemctl enable skepd.service
systemctl restart skepd.service
systemctl is-active --quiet skepd.service
attempt=0
while [ ! -S /run/skep/skepd.sock ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ]; then
    systemctl status skepd.service --no-pager >&2 || true
    echo "skepd did not create its control socket" >&2
    exit 1
  fi
  sleep 0.1
done
/usr/local/bin/skepctl call ping --compact
