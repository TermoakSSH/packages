#!/usr/bin/env bash
# Arch Linux: key added and locally signed, [termoak] with DatabaseRequired.
. /tests/common.sh

step "pacman keyring"
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinux >/dev/null 2>&1
pacman -Sy --noconfirm --needed curl >/dev/null

step "unsigned access must fail (key not trusted yet)"
cat >>/etc/pacman.conf <<CONF

[termoak]
SigLevel = Required DatabaseRequired
Server = $REPO/arch/\$arch
CONF
if pacman -Sy --noconfirm >/tmp/s.log 2>&1; then cat /tmp/s.log; fail "pacman accepted the database without the key"; fi
grep -i 'signature\|key' /tmp/s.log | head -3
ok "pacman rejects the database without the key"

step "add the key"
curl -fsSL -o /tmp/termoak.asc "$REPO/termoak.asc"
pacman-key --add /tmp/termoak.asc
pacman-key --lsign-key "$FPR"

step "install cli + server + desktop"
pacman -Sy --noconfirm termoak-cli termoak-server termoak
check_cli
check_server
check_desktop

step "downgrade the desktop to 0.2.1 from the pool and upgrade again"
pacman -U --noconfirm "$REPO/arch/x86_64/termoak-0.2.1-1-x86_64.pkg.tar.zst"
pacman -Q termoak | grep -q '0.2.1-1' || fail "downgrade"
pacman -Su --noconfirm
pacman -Q termoak | grep -q '0.2.2-1' || fail "desktop not upgraded"

step "upgrade cli + server to package release 2"
mark_config
sed -i "s|^Server = .*/arch/|Server = $REPO2/arch/|" /etc/pacman.conf
pacman -Syu --noconfirm
pacman -Q termoak-cli termoak-server | grep -- '-2$' || fail "not upgraded to -2"
check_upgraded

step "remove"
pacman -Rns --noconfirm termoak-cli termoak-server termoak
[ -e /etc/termoak/config.toml.pacsave ] && echo "  config saved as config.toml.pacsave (expected: it was modified)"
check_removed
echo; echo "ALL OK"
