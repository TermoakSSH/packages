#!/usr/bin/env bash
# Installs the packages of the staging repository in Docker containers of
# several distributions, the way the index page tells users to, and checks
# signatures, the installed files, an upgrade and the removal.
#
# Nothing is deployed: the staging repository is copied to a temporary
# directory (with the .repo file pointing to it) and served on 127.0.0.1 with
# python3's http.server; the containers use --network host. A second copy,
# with termoak-cli and termoak-server rebuilt as package release 2 (by
# publish.sh --release 2), is served too to test the upgrade path.
#
# Usage: scripts/test-repo.sh [--out DIR] [--rmi] [image ...]
#   --out DIR   staging repository (default: <repo>/out/repo)
#   --rmi       remove the distro images afterwards (they are pulled on use)
#   image       limit to these images (default: all of the list below)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/out/repo"
fpr="${TERMOAK_REPO_KEY:-BDD6B45E003E53F1B9DE70932C813822C95C7F5B}"
rmi=false
images=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --rmi) rmi=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) images+=("$1"); shift ;;
  esac
done

# image | test script | extra environment
all=(
  "debian:12|apt.sh|"
  "ubuntu:22.04|apt.sh|"
  "ubuntu:24.04|apt.sh|NO_RECOMMENDS=1"
  "fedora:latest|dnf.sh|"
  "almalinux:9|dnf.sh|DESKTOP=no"
  "opensuse/tumbleweed|zypper.sh|"
  "opensuse/leap:16.0|zypper.sh|"
  "archlinux:latest|pacman.sh|"
)
[ ${#images[@]} -gt 0 ] || for e in "${all[@]}"; do images+=("${e%%|*}"); done

[ -f "$out/deb/dists/stable/InRelease" ] || { echo "no repository in $out; run scripts/publish.sh first" >&2; exit 1; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/termoak-test.XXXXXX")"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

p1="$(free_port)"
p2="$(free_port)"
url1="http://127.0.0.1:$p1"
url2="http://127.0.0.1:$p2"

log "copying the staging repository"
cp -a "$out" "$tmp/repo1"
cp -a "$out" "$tmp/repo2"
log "rebuilding termoak-cli and termoak-server as package release 2 (upgrade test)"
"$root/scripts/publish.sh" --out "$tmp/repo2" --only termoak-cli,termoak-server --release 2 \
  >"$tmp/publish2.log" 2>&1 || { cat "$tmp/publish2.log"; exit 1; }
sed -i "s|https://pkg.termoak.com|$url1|g" "$tmp/repo1/rpm/termoak.repo"
sed -i "s|https://pkg.termoak.com|$url2|g" "$tmp/repo2/rpm/termoak.repo"

python3 -m http.server "$p1" --bind 127.0.0.1 --directory "$tmp/repo1" >"$tmp/http1.log" 2>&1 &
pids+=($!)
python3 -m http.server "$p2" --bind 127.0.0.1 --directory "$tmp/repo2" >"$tmp/http2.log" 2>&1 &
pids+=($!)
for _ in $(seq 50); do
  curl -fsS -o /dev/null "$url1/index.html" 2>/dev/null && curl -fsS -o /dev/null "$url2/index.html" 2>/dev/null && break
  sleep 0.2
done

logs="$root/out/test-logs"
mkdir -p "$logs"
results=()
for img in "${images[@]}"; do
  entry=""
  for e in "${all[@]}"; do [ "${e%%|*}" = "$img" ] && entry="$e"; done
  [ -n "$entry" ] || { echo "unknown image: $img" >&2; exit 2; }
  IFS='|' read -r _ script extra <<<"$entry"
  envs=(-e "REPO=$url1" -e "REPO2=$url2" -e "FPR=$fpr")
  [ -n "$extra" ] && envs+=(-e "$extra")
  logf="$logs/$(echo "$img" | tr '/:' '__').log"
  log "$img ($script${extra:+, $extra})"
  if docker run --rm --network host -v "$root/tests:/tests:ro" "${envs[@]}" "$img" \
    bash "/tests/$script" >"$logf" 2>&1; then
    results+=("PASS  $img")
  else
    results+=("FAIL  $img  (see $logf)")
    tail -n 15 "$logf" | sed 's/^/    /'
  fi
  if $rmi; then docker rmi -f "$img" >/dev/null 2>&1 || true; fi
done

echo
printf '%s\n' "${results[@]}"
printf '%s\n' "${results[@]}" | grep -q '^FAIL' && exit 1 || exit 0
