#!/bin/sh
# termoak-server post-install / post-upgrade (deb, rpm and pacman).
#   deb:    configure <old-version or empty>
#   rpm:    1 = install, 2+ = upgrade
#   pacman: post_install <new>, post_upgrade <new> <old>
# The services are never enabled or started here.
termoak_upgrade=false
case "$1" in
  configure) [ -n "$2" ] && termoak_upgrade=true ;;
  1) ;;
  [2-9]) termoak_upgrade=true ;;
  *) [ -n "$2" ] && termoak_upgrade=true ;;
esac

if command -v systemd-tmpfiles >/dev/null 2>&1; then
  systemd-tmpfiles --create /usr/lib/tmpfiles.d/termoak.conf >/dev/null 2>&1 || true
fi
if [ ! -d /var/lib/termoak ]; then
  install -d -m 0700 -o termoak -g termoak /var/lib/termoak
fi
# The server runs as `termoak` and must read its configuration, which may
# hold secrets (SMTP password...): root:termoak 0640.
if [ -f /etc/termoak/config.toml ]; then
  chgrp termoak /etc/termoak/config.toml && chmod 0640 /etc/termoak/config.toml
fi

if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if [ "$termoak_upgrade" = true ]; then
  # Restarting termoak-server keeps the sessions (they live in the
  # termoak-sessions holder, which is not restarted).
  if [ -d /run/systemd/system ]; then
    systemctl try-restart termoak-server.service >/dev/null 2>&1 || true
  fi
else
  cat <<'NOTE'

Termoak server installed. It is not started automatically:
  1. Review /etc/termoak/config.toml (public_url, registration, TLS...).
  2. Optional: AI provider keys and TERMOAK_SMTP_URL in /etc/termoak/env
     (root-only, mode 0600).
  3. sudo systemctl enable --now termoak-sessions termoak-server
The server listens on 0.0.0.0:7722; the first user to sign up becomes the
administrator. Guide: https://github.com/TermoakSSH/server/blob/main/docs/DEPLOYMENT.md

NOTE
fi
