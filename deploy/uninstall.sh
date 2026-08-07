#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh must run as root" >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now skepd.service >/dev/null 2>&1 || true
fi

rm -f /etc/systemd/system/skepd.service
rm -f /etc/sudoers.d/skep
rm -f /usr/local/bin/skepd
rm -f /usr/local/bin/skepctl
rm -f /run/skep/skepd.sock

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl reset-failed skepd.service >/dev/null 2>&1 || true
fi

echo "Removed the Skep host service. /var/lib/skep and Microsandbox were preserved."
