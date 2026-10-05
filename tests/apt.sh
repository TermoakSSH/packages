#!/usr/bin/env bash
# Debian / Ubuntu: deb822 source with Signed-By, as on the index page.
. /tests/common.sh
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o Dpkg::Use-Pty=0 -q)
"${APT[@]}" update >/dev/null
"${APT[@]}" install -y --no-install-recommends ca-certificates curl >/dev/null

step "unsigned access must fail (no Signed-By key)"
cat >/etc/apt/sources.list.d/termoak.sources <<SRC
Types: deb
URIs: $REPO/deb
Suites: stable
Components: main
SRC
"${APT[@]}" update >/tmp/u.log 2>&1 || true
if grep -q 'NO_PUBKEY\|not signed' /tmp/u.log; then
  grep 'NO_PUBKEY\|not signed' /tmp/u.log | head -2
  ok "apt rejects the repository without the key"
else
  cat /tmp/u.log; fail "apt accepted the repository without the key"
fi

step "add key and source"
install -d -m 0755 /usr/share/keyrings
curl -fsSL "$REPO/termoak.gpg" -o /usr/share/keyrings/termoak.gpg
cat >/etc/apt/sources.list.d/termoak.sources <<SRC
Types: deb
URIs: $REPO/deb
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/termoak.gpg
SRC
"${APT[@]}" update 2>&1 | tee /tmp/u.log
if grep -qiE '^(W|E):' /tmp/u.log; then fail "apt update warnings/errors"; fi
apt-cache policy termoak termoak-cli termoak-server

step "install cli + server${NO_RECOMMENDS:+ (no recommends: no systemd, useradd path)}"
"${APT[@]}" install -y ${NO_RECOMMENDS:+--no-install-recommends} termoak-cli termoak-server
check_cli
check_server

step "install the desktop 0.2.1, then upgrade"
"${APT[@]}" install -y --no-install-recommends termoak=0.2.1-1
dpkg-query -W termoak
"${APT[@]}" install -y --no-install-recommends --only-upgrade termoak
[ "$(dpkg-query -W -f '${Version}' termoak)" = "$(apt-cache policy termoak | awk '/Candidate/ {print $2}')" ] || fail "desktop not upgraded"
dpkg-query -W termoak
check_desktop

step "upgrade cli + server to package release 2"
mark_config
sed -i "s|^URIs: .*|URIs: $REPO2/deb|" /etc/apt/sources.list.d/termoak.sources
"${APT[@]}" update >/dev/null
"${APT[@]}" install -y --only-upgrade termoak-cli termoak-server
dpkg-query -W termoak-cli termoak-server | grep -- '-2$' || fail "not upgraded to -2"
check_upgraded

step "remove and purge"
"${APT[@]}" remove -y termoak-cli termoak-server termoak
[ -f /etc/termoak/config.toml ] || fail "conffile removed before purge"
"${APT[@]}" purge -y termoak-server
[ ! -e /etc/termoak/config.toml ] || fail "conffile kept after purge"
check_removed
echo; echo "ALL OK"
