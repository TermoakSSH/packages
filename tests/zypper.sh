#!/usr/bin/env bash
# openSUSE: key imported first, then the .repo file, as on the index page.
. /tests/common.sh
ZYP=(zypper --non-interactive --quiet)

step "add the key and the repository"
rpm --import "$REPO/termoak.asc"
zypper --non-interactive addrepo --refresh "$REPO/rpm/termoak.repo"
zypper lr termoak | grep -i 'autorefresh *: *\(yes\|on\)' || fail "autorefresh is off"
# No --gpg-auto-import-keys: the refresh must verify repomd.xml.asc with the
# imported key.
zypper --non-interactive refresh termoak 2>&1 | tee /tmp/r.log
grep -qi 'unsigned\|signature verification failed\|not signed' /tmp/r.log && fail "refresh: signature problem"
zypper lr -d termoak

step "install cli + server"
"${ZYP[@]}" install --no-recommends termoak-cli termoak-server
check_cli
check_server

step "install the desktop 0.2.1, then upgrade"
"${ZYP[@]}" install --no-recommends --oldpackage termoak=0.2.1-1
rpm -q termoak
"${ZYP[@]}" update --no-recommends termoak
rpm -q termoak | grep -q 'termoak-0.2.2' || fail "desktop not upgraded"
check_desktop

step "upgrade cli + server to package release 2"
mark_config
sed -i "s|^baseurl=.*|baseurl=$REPO2/rpm/\$basearch|" /etc/zypp/repos.d/termoak.repo
zypper --non-interactive refresh termoak >/dev/null
"${ZYP[@]}" update termoak-cli termoak-server
rpm -q termoak-cli termoak-server | grep -- '-2\.' || fail "not upgraded to -2"
check_upgraded

step "remove"
"${ZYP[@]}" remove termoak-cli termoak-server termoak
check_removed
echo; echo "ALL OK"
