# shellcheck shell=bash
# Shared checks for the distro tests (sourced inside the test containers).
# Environment: REPO (URL of the staging repository), REPO2 (same repository
# plus termoak-cli/termoak-server rebuilt with package release 2), FPR.
set -euo pipefail

step() { printf '\n\033[1;36m--- %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*"; exit 1; }
ok() { printf '\033[1;32mok\033[0m %s\n' "$*"; }

check_cli() {
  step "termoak --version"
  [ -x /usr/bin/termoak ] || fail "no /usr/bin/termoak"
  termoak --version || fail "termoak --version"
  ok "cli"
}

check_server() {
  step "termoak-server --version, user, config, units"
  [ -x /usr/bin/termoak-server ] || fail "no /usr/bin/termoak-server"
  termoak-server --version || fail "termoak-server --version"
  getent passwd termoak || fail "no termoak user"
  getent group termoak || fail "no termoak group"
  [ -d /var/lib/termoak ] || fail "no /var/lib/termoak"
  [ "$(stat -c '%U:%G %a' /var/lib/termoak)" = "termoak:termoak 700" ] ||
    fail "/var/lib/termoak is $(stat -c '%U:%G %a' /var/lib/termoak)"
  [ "$(stat -c '%U:%G %a' /etc/termoak/config.toml)" = "root:termoak 640" ] ||
    fail "/etc/termoak/config.toml is $(stat -c '%U:%G %a' /etc/termoak/config.toml)"
  grep -q '^data_dir = "/var/lib/termoak"' /etc/termoak/config.toml || fail "data_dir"
  grep -q '^holder_socket = "/run/termoak-sessions/sessions.sock"' /etc/termoak/config.toml || fail "holder_socket"
  for u in termoak-server termoak-sessions; do
    f=/usr/lib/systemd/system/$u.service
    [ -f "$f" ] || fail "missing $f"
    grep -q '^ExecStart=/usr/bin/termoak-server ' "$f" || fail "$f ExecStart"
  done
  # The server can read its config as the termoak user.
  if command -v setpriv >/dev/null; then
    setpriv --reuid=termoak --regid=termoak --init-groups \
      /usr/bin/termoak-server --config /etc/termoak/config.toml ai-providers >/dev/null 2>&1 ||
      setpriv --reuid=termoak --regid=termoak --init-groups cat /etc/termoak/config.toml >/dev/null ||
      fail "termoak cannot read its config"
    ok "config readable by termoak"
  fi
  if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify /usr/lib/systemd/system/termoak-server.service \
      /usr/lib/systemd/system/termoak-sessions.service || fail "systemd-analyze verify"
    ok "units verified"
  fi
  ok "server"
}

check_desktop() {
  step "termoak-desktop libraries"
  [ -x /usr/bin/termoak-desktop ] || fail "no /usr/bin/termoak-desktop"
  ls /usr/share/applications/com.termoak.Termoak.desktop /usr/share/icons/hicolor/256x256/apps/termoak.png \
    /usr/share/icons/hicolor/scalable/apps/termoak.svg >/dev/null || fail "desktop entry or icons"
  if ldd /usr/bin/termoak-desktop | grep 'not found'; then fail "missing linked libraries"; fi
  ldd /usr/bin/termoak-desktop | sed 's/^/  /'
  # Loaded at run time with dlopen.
  for lib in libvulkan.so.1 libwayland-client.so.0; do
    ldconfig -p | grep "$lib" >/dev/null || fail "$lib (dlopen) not installed"
    ok "$lib present"
  done
  ok "desktop"
}

# Before an upgrade: a local change that must survive it.
mark_config() { echo "# local change kept across upgrades" >>/etc/termoak/config.toml; }

check_upgraded() {
  step "after upgrade"
  grep -q '^# local change kept across upgrades' /etc/termoak/config.toml || fail "config change lost"
  [ "$(stat -c '%U:%G %a' /etc/termoak/config.toml)" = "root:termoak 640" ] || fail "config owner after upgrade"
  getent passwd termoak >/dev/null || fail "user lost"
  termoak --version
  termoak-server --version
  ok "upgrade kept the configuration"
}

check_removed() {
  step "after removal"
  [ ! -e /usr/bin/termoak-server ] || fail "termoak-server still installed"
  [ ! -e /usr/bin/termoak ] || fail "termoak still installed"
  [ ! -e /usr/lib/systemd/system/termoak-server.service ] || fail "unit still installed"
  [ -d /var/lib/termoak ] && echo "  /var/lib/termoak kept (expected)"
  ok "removed"
}
