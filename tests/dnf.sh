#!/usr/bin/env bash
# Fedora / RHEL clones: the .repo file (gpgcheck + repo_gpgcheck).
. /tests/common.sh
DNF=(dnf -y -q --setopt=install_weak_deps=False)

step "add the repository"
if dnf config-manager --help 2>&1 | grep -q addrepo; then
  dnf config-manager addrepo --from-repofile="$REPO/rpm/termoak.repo"   # dnf5
else
  curl -fsSL -o /etc/yum.repos.d/termoak.repo "$REPO/rpm/termoak.repo"   # dnf4
fi
cat /etc/yum.repos.d/termoak.repo
grep -q '^gpgcheck=1' /etc/yum.repos.d/termoak.repo && grep -q '^repo_gpgcheck=1' /etc/yum.repos.d/termoak.repo

step "install cli + server (dnf imports the key from gpgkey=)"
dnf -y --setopt=install_weak_deps=False install termoak-cli termoak-server 2>&1 | tee /tmp/i.log
grep -qi 'BDD6B45E003E53F1B9DE70932C813822C95C7F5B\|2C813822C95C7F5B\|imported' /tmp/i.log || fail "no key import in the log"
rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'
check_cli
command -v systemd-analyze >/dev/null || "${DNF[@]}" install systemd >/dev/null 2>&1 || true
check_server

step "signatures of the downloaded packages"
mkdir -p /tmp/rpms
for p in termoak-cli termoak-server; do
  f="$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm' "$p")"
  curl -fsSL -o "/tmp/rpms/$f" "$REPO/rpm/$(uname -m)/$f"
done
rpm -K /tmp/rpms/*.rpm
if rpm -K /tmp/rpms/*.rpm | grep -v 'signatures OK'; then fail "rpm -K"; fi

if [ "${DESKTOP:-yes}" = yes ]; then
  step "install the desktop 0.2.1, then upgrade"
  "${DNF[@]}" install termoak-0.2.1
  rpm -q termoak
  "${DNF[@]}" upgrade termoak
  rpm -q termoak | grep -q 'termoak-0.2.2' || fail "desktop not upgraded"
  rpm -q termoak
  check_desktop
else
  step "desktop must be refused (needs glibc >= 2.35)"
  if dnf -y install termoak >/tmp/d.log 2>&1; then fail "desktop installed on an old glibc"; fi
  grep -i 'GLIBC_2.35' /tmp/d.log || { cat /tmp/d.log; fail "unexpected error"; }
  ok "refused: GLIBC_2.35"
fi

step "upgrade cli + server to package release 2"
mark_config
sed -i "s|^baseurl=.*|baseurl=$REPO2/rpm/\$basearch|" /etc/yum.repos.d/termoak.repo
dnf -q clean all >/dev/null
"${DNF[@]}" upgrade termoak-cli termoak-server
rpm -q termoak-cli termoak-server | grep -- '-2\.' || fail "not upgraded to -2"
check_upgraded

step "remove"
"${DNF[@]}" remove termoak-cli termoak-server
rpm -q termoak >/dev/null && "${DNF[@]}" remove termoak
ls /etc/termoak/ || true
check_removed
echo; echo "ALL OK"
