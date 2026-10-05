#!/bin/sh
# termoak-server post-removal. The `termoak` user and /var/lib/termoak (the
# database and keys) are kept; delete them by hand if no longer needed.
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
