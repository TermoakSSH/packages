#!/usr/bin/env bash
# Builds the Termoak Flatpak from source and exports it to the signed OSTree
# repository. Runs INSIDE the termoak-flatpak container
# (docker/flatpak.Dockerfile); start it with scripts/flatpak.sh, which mounts:
#   /src      this repository (read-only)
#   /desktop  a checkout of TermoakSSH/desktop with flatpak/ (read-only)
#   /repo     the staging repository; the Flatpak repository goes to
#             /repo/flatpak (repo/, termoak.flatpakrepo, the .flatpakref)
#   /cache    persistent cache: system/ (the flatpak installation with the
#             runtimes, mounted at /var/lib/flatpak) and state/
#             (flatpak-builder's downloads, git mirrors and build cache)
#   /gnupg    GNUPGHOME with the signing key (read-only)
# Environment: FPR (signing key), KEEP (commits kept per ref), BUILD=0 (only
# summary, appstream and the .flatpakrepo/.flatpakref), SMOKE=0 (skip the
# install-and-run test), LINT=1 (Flathub's linter on the manifest and the
# repository), JOBS (parallel jobs of the build, default 2).
set -euo pipefail
shopt -s inherit_errexit

: "${FPR:?}" "${KEEP:=3}" "${BUILD:=1}" "${SMOKE:=1}" "${LINT:=0}" "${JOBS:=2}"
# gpgme (OSTree's signing) cannot work on the read-only /gnupg: it needs
# lock files and to start gpg-agent there. A writable home in the container
# with copies of the public keyring and trustdb, and the private keys
# directory linked (read-only, never copied).
install -d -m 700 /tmp/gnupg
cp /gnupg/pubring.kbx /gnupg/trustdb.gpg /tmp/gnupg/
ln -s /gnupg/private-keys-v1.d /tmp/gnupg/private-keys-v1.d
export GNUPGHOME=/tmp/gnupg
APP=com.termoak.Termoak
MANIFEST=/desktop/flatpak/$APP.yml
OUT=/repo/flatpak
REPO=$OUT/repo
BASE=https://pkg.termoak.com/flatpak
FLATHUB=https://dl.flathub.org/repo/flathub.flatpakrepo

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

mkdir -p "$OUT" /cache/state
flatpak remote-add --if-not-exists flathub "$FLATHUB"

# The public key, binary, for the summary, the .flatpakrepo and the .flatpakref.
gpg --batch --export "$FPR" >/tmp/termoak.gpg 2>/dev/null
[ -s /tmp/termoak.gpg ] || { echo "key $FPR not found in $GNUPGHOME" >&2; exit 1; }
key_b64="$(base64 -w0 /tmp/termoak.gpg)"

if [ "$BUILD" = 1 ]; then
  [ -f "$MANIFEST" ] || { echo "no $MANIFEST" >&2; exit 1; }
  tag="$(sed -n 's/^ *tag: *//p' "$MANIFEST" | head -1)"
  log "building $APP ($tag) with flatpak-builder"
  # The manifest directory is read-only: work on a copy (cargo-sources.json
  # and patches/ are next to it).
  rm -rf /tmp/manifest && cp -r /desktop/flatpak /tmp/manifest
  cd /cache
  flatpak-builder --disable-rofiles-fuse --state-dir=/cache/state \
    --install-deps-from=flathub --jobs="$JOBS" --force-clean \
    --default-branch=stable --repo="$REPO" --subject="Termoak ${tag#desktop-v}" \
    --gpg-sign="$FPR" --gpg-homedir="$GNUPGHOME" \
    /cache/build "/tmp/manifest/$APP.yml"
  # Version of what was built (the newest <release> of its metainfo) and the
  # icon for the .flatpakrepo/.flatpakref.
  python3 - "/cache/build/files/share/metainfo/$APP.metainfo.xml" >"$OUT/VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().find('releases/release').get('version'))
PY
  install -m 644 "/cache/build/files/share/icons/hicolor/scalable/apps/$APP.svg" "$OUT/termoak.svg"
  rm -rf /cache/build /tmp/manifest
fi
[ -d "$REPO/objects" ] || { echo "no repository in $REPO yet: build it first" >&2; exit 1; }

log "summary, appstream branch and static deltas (keeping $KEEP commits per ref)"
flatpak build-update-repo --generate-static-deltas --prune --prune-depth="$KEEP" \
  --title="Termoak" --comment="Termoak SSH client by Ohz Digital SL" \
  --homepage="https://pkg.termoak.com/#flatpak" --icon="$BASE/termoak.svg" \
  --default-branch=stable --gpg-import=/tmp/termoak.gpg \
  --gpg-sign="$FPR" --gpg-homedir="$GNUPGHOME" "$REPO"

log "termoak.flatpakrepo and $APP.flatpakref"
cat >"$OUT/termoak.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Termoak
Url=$BASE/repo/
Homepage=https://pkg.termoak.com/#flatpak
Comment=Termoak SSH client by Ohz Digital SL
Description=Signed Flatpak repository of Termoak, the SSH client with persistent sessions.
Icon=$BASE/termoak.svg
DefaultBranch=stable
GPGKey=$key_b64
EOF
cat >"$OUT/$APP.flatpakref" <<EOF
[Flatpak Ref]
Name=$APP
Branch=stable
Title=Termoak
Url=$BASE/repo/
SuggestRemoteName=termoak
RuntimeRepo=$FLATHUB
IsRuntime=false
Homepage=https://termoak.com
Comment=SSH client with persistent sessions
Icon=$BASE/termoak.svg
GPGKey=$key_b64
EOF
chmod 644 "$OUT"/*.flatpakrepo "$OUT"/*.flatpakref

if [ "$SMOKE" = 1 ]; then
  log "smoke test: install from the staging repository and run"
  flatpak remote-delete --force termoak-staging 2>/dev/null || true
  flatpak remote-add --gpg-import=/tmp/termoak.gpg termoak-staging "file://$REPO"
  flatpak install -y --noninteractive termoak-staging "$APP"
  flatpak info "$APP"
  out="$(flatpak run --command=termoak-desktop "$APP" --version)"
  echo "$out"
  [ "$out" = "termoak-desktop $(cat "$OUT/VERSION")" ] || { echo "unexpected --version: $out" >&2; exit 1; }
  # The window under Xvfb (software Vulkan of the GL extension): still
  # running after 15 s.
  xvfb-run -a -s "-screen 0 1280x800x24" bash -c '
    flatpak run --env=RUST_LOG=info '"$APP"' >/tmp/run.log 2>&1 &
    pid=$!
    sleep 15
    if kill -0 $pid 2>/dev/null; then
      echo "the app is running after 15 s"; kill $pid; wait $pid 2>/dev/null; exit 0
    fi
    wait $pid; echo "the app exited with $?"; exit 1' || { tail -n 40 /tmp/run.log; exit 1; }
  tail -n 5 /tmp/run.log
  flatpak uninstall -y --noninteractive "$APP"
  flatpak remote-delete --force termoak-staging
fi

if [ "$LINT" = 1 ]; then
  log "Flathub linter (org.flatpak.Builder)"
  flatpak install -y --noninteractive flathub org.flatpak.Builder >/dev/null
  # The linter runs in its own sandbox, which has its own /tmp: the manifest
  # goes to the cache volume, shared with it.
  rm -rf /cache/lint && cp -r /desktop/flatpak /cache/lint
  echo "--- flatpak-builder-lint manifest"
  flatpak run --filesystem=/cache/lint:ro --command=flatpak-builder-lint org.flatpak.Builder \
    manifest "/cache/lint/$APP.yml" || true
  echo "--- flatpak-builder-lint repo"
  flatpak run --filesystem="$REPO":ro --command=flatpak-builder-lint org.flatpak.Builder \
    repo "$REPO" || true
  rm -rf /cache/lint
fi
log "flatpak repository ready: $(cat "$OUT/VERSION" 2>/dev/null || echo '?')"
