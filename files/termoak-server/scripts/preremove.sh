#!/bin/sh
# termoak-server pre-removal: stops and disables the services only when the
# package is removed, not on upgrades.
#   deb: remove | upgrade | ...   rpm: 0 = erase, 1+ = upgrade
#   pacman: pre_remove <old> (removal only)
case "$1" in
  upgrade|failed-upgrade|deconfigure|[1-9]) ;;
  *)
    if [ -d /run/systemd/system ]; then
      systemctl disable --now termoak-server.service termoak-sessions.service >/dev/null 2>&1 || true
    fi
    ;;
esac
