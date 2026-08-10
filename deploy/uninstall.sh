#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh must run as root" >&2
  exit 1
fi

PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *)
    echo "usage: uninstall.sh [--purge]" >&2
    exit 2
    ;;
esac

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

if [ "$PURGE" -eq 1 ]; then
  rm -rf -- /var/lib/skep /run/skep
  if command -v getent >/dev/null 2>&1 && getent group skep >/dev/null 2>&1; then
    groupdel skep
  fi
  echo "Erased the Skep host service, runtime, workspaces, templates, volumes, and exports."
else
  echo "Removed the Skep host service. /var/lib/skep and Microsandbox were preserved."
fi
