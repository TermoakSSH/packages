#!/usr/bin/env bash
# Builds the Termoak desktop Flatpak (com.termoak.Termoak) from source with
# flatpak-builder and the manifest of TermoakSSH/desktop (flatpak/), and
# updates the signed OSTree repository in <out>/flatpak/repo, with its
# summary and appstream branch, termoak.flatpakrepo and
# com.termoak.Termoak.flatpakref. Called by scripts/publish.sh (--only
# flatpak); can also be run on its own.
#
# Everything runs in the termoak-flatpak Docker image
# (docker/flatpak.Dockerfile, built on first use); see scripts/build-flatpak.sh.
# The build is heavy (a full Rust release build with fat LTO): run it under
# the build lock, e.g. `flock /root/.termoak-build.lock scripts/flatpak.sh`.
#
# Usage: scripts/flatpak.sh [options]
#   --desktop-ref REF   branch or tag of TermoakSSH/desktop whose flatpak/
#                       directory (manifest, cargo-sources.json, patches) is
#                       built (default: main). The manifest names the
#                       release tag that is compiled.
#   --desktop-dir DIR   a local checkout of TermoakSSH/desktop instead
#   --out DIR           staging repository (default: <repo>/out/repo)
#   --keep N            commits kept per ref (default 3)
#   --no-build          only regenerate the summary, appstream branch and the
#                       .flatpakrepo/.flatpakref
#   --no-smoke          skip the test (install from the staging repository,
#                       --version, start the window under Xvfb)
#   --lint              run Flathub's linter (flatpak-builder-lint of
#                       org.flatpak.Builder) on the manifest and the repository
#   --rebuild-image     rebuild the termoak-flatpak image first
#   --verify-remote     only check what pkg.termoak.com serves, as a user
#                       would: remote-add of the published .flatpakrepo (its
#                       key), install com.termoak.Termoak from it, run
#                       --version (a --user installation in a throwaway
#                       container; the runtime comes from the cache)
#
# Cache: <repo>/out/flatpak-cache (the runtimes and SDK, ~4 GB, and
# flatpak-builder's downloads); delete it to free the space.
# Environment: GNUPGHOME (default /root/.config/termoak/repo-gpg),
# TERMOAK_REPO_KEY (fingerprint).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image=termoak-flatpak
gnupghome="${GNUPGHOME:-/root/.config/termoak/repo-gpg}"
fpr="${TERMOAK_REPO_KEY:-BDD6B45E003E53F1B9DE70932C813822C95C7F5B}"
ref=main desktop_dir="" out="$root/out/repo" keep=3
build=1 smoke=1 lint=0 rebuild_image=false verify_remote=false

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --desktop-ref) ref="$2"; shift 2 ;;
    --desktop-dir) desktop_dir="$(cd "$2" && pwd)"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --keep) keep="$2"; shift 2 ;;
    --no-build) build=0; shift ;;
    --no-smoke) smoke=0; shift ;;
    --lint) lint=1; shift ;;
    --rebuild-image) rebuild_image=true; shift ;;
    --verify-remote) verify_remote=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "--keep must be a positive integer" >&2; exit 2; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
GNUPGHOME="$gnupghome" gpg --batch --list-secret-keys "$fpr" >/dev/null 2>&1 ||
  { echo "signing key $fpr not found in $gnupghome" >&2; exit 1; }

if $rebuild_image || ! docker image inspect "$image" >/dev/null 2>&1; then
  log "building the $image image"
  docker build -q -t "$image" -f "$root/docker/flatpak.Dockerfile" "$root/docker" >/dev/null
fi

# bubblewrap (flatpak-builder's build sandbox, the icon validation of the
# export and flatpak run) creates namespaces and mounts /proc: as root in the
# container that needs CAP_SYS_ADMIN and CAP_NET_ADMIN (the loopback of a new
# network namespace), no seccomp/AppArmor filters and unmasked /proc paths.
# Still not --privileged: no devices, and the capabilities are those of the
# container's namespaces.
bwrap_opts=(--cap-add SYS_ADMIN --cap-add NET_ADMIN
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined
  --security-opt systempaths=unconfined)

if $verify_remote; then
  log "checking https://pkg.termoak.com/flatpak as a client"
  [ -d "$root/out/flatpak-cache/system/runtime" ] ||
    { echo "no runtime in out/flatpak-cache: build first" >&2; exit 1; }
  docker run --rm "${bwrap_opts[@]}" \
    -v "$root/out/flatpak-cache/system:/var/lib/flatpak:ro" \
    "$image" bash -euo pipefail -c '
      flatpak --user remote-add --if-not-exists termoak https://pkg.termoak.com/flatpak/termoak.flatpakrepo
      flatpak --user remote-ls termoak
      flatpak --user install -y --noninteractive termoak com.termoak.Termoak
      flatpak info --user com.termoak.Termoak
      flatpak run --command=termoak-desktop com.termoak.Termoak --version
      curl -fsSI https://pkg.termoak.com/flatpak/com.termoak.Termoak.flatpakref | grep -i "^content-type: application/vnd.flatpak.ref"
      curl -fsSI https://pkg.termoak.com/flatpak/termoak.flatpakrepo | grep -i "^content-type: application/vnd.flatpak.repo"'
  log "pkg.termoak.com/flatpak verified"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/termoak-flatpak.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ -z "$desktop_dir" ]; then
  log "TermoakSSH/desktop $ref: flatpak/"
  git clone -q --depth 1 --branch "$ref" https://github.com/TermoakSSH/desktop.git "$work/desktop"
  desktop_dir="$work/desktop"
fi
[ -f "$desktop_dir/flatpak/com.termoak.Termoak.yml" ] ||
  { echo "$desktop_dir has no flatpak/com.termoak.Termoak.yml" >&2; exit 1; }

mkdir -p "$out" "$root/out/flatpak-cache/system" "$root/out/flatpak-cache/state"
docker run --rm "${bwrap_opts[@]}" \
  -v "$root:/src:ro" \
  -v "$desktop_dir:/desktop:ro" \
  -v "$(cd "$out" && pwd):/repo" \
  -v "$root/out/flatpak-cache:/cache" \
  -v "$root/out/flatpak-cache/system:/var/lib/flatpak" \
  -v "$gnupghome:/gnupg:ro" \
  -e FPR="$fpr" -e KEEP="$keep" -e BUILD="$build" -e SMOKE="$smoke" -e LINT="$lint" \
  "$image" bash /src/scripts/build-flatpak.sh
