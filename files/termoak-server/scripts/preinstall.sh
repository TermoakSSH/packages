#!/bin/sh
# termoak-server: creates the `termoak` system user and group before the
# files are unpacked. Shared by deb, rpm and pacman (nfpm), so it relies only
# on POSIX sh and never calls `exit` (pacman runs it inside a function).
if ! getent passwd termoak >/dev/null 2>&1; then
  if command -v systemd-sysusers >/dev/null 2>&1; then
    printf 'u termoak - "Termoak server" /var/lib/termoak\n' | systemd-sysusers - >/dev/null 2>&1 || true
  fi
fi
if ! getent passwd termoak >/dev/null 2>&1; then
  getent group termoak >/dev/null 2>&1 || groupadd --system termoak
  nologin=/usr/sbin/nologin
  [ -x "$nologin" ] || nologin=/sbin/nologin
  useradd --system --gid termoak --home-dir /var/lib/termoak --no-create-home \
    --shell "$nologin" --comment "Termoak server" termoak
fi
