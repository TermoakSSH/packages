#!/usr/bin/env bash
# Builds the Termoak Linux packages from the published GitHub releases and
# regenerates the signed APT, RPM and pacman repositories in a staging
# directory; optionally copies it to the web root of pkg.termoak.com.
#
# Everything runs locally: downloads with curl, packaging, metadata and
# signing in the termoak-packaging Docker image (docker/Dockerfile, built on
# first use). Safe to run again: packages already in the staging repository
# are not rebuilt, only the metadata and the index page are regenerated.
#
# Usage: scripts/publish.sh [options]
#   --desktop VERSION   desktop release to package (default: latest published)
#   --cli VERSION       CLI release (default: latest published cli-v*)
#   --server VERSION    server release (default: latest published server-v*)
#   --only LIST         packages to build, comma-separated
#                       (termoak,termoak-cli,termoak-server; default: all)
#   --no-build          build nothing; only regenerate metadata and index
#   --release N         package release of what is built now (default 1;
#                       raise it to republish the same version with packaging
#                       changes)
#   --keep N            versions kept per package and arch (default 3)
#   --out DIR           staging repository (default: <repo>/out/repo)
#   --deploy DIR        copy the staging repository to DIR when done
#                       (e.g. /var/www/pkg.termoak.com)
#   --rebuild-image     rebuild the termoak-packaging image first
#
# Environment: GNUPGHOME (default /root/.config/termoak/repo-gpg),
# TERMOAK_REPO_KEY (fingerprint), GITHUB_TOKEN (optional, for API limits;
# defaults to /root/.config/termoak/github-token when readable).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image=termoak-packaging
gnupghome="${GNUPGHOME:-/root/.config/termoak/repo-gpg}"
fpr="${TERMOAK_REPO_KEY:-BDD6B45E003E53F1B9DE70932C813822C95C7F5B}"
org=TermoakSSH

want_desktop="" want_cli="" want_server=""
only="termoak,termoak-cli,termoak-server"
build=true release=1 keep=3 deploy="" rebuild_image=false
out="$root/out/repo"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --desktop) want_desktop="${2#v}"; shift 2 ;;
    --cli) want_cli="${2#v}"; shift 2 ;;
    --server) want_server="${2#v}"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --no-build) build=false; shift ;;
    --release) release="$2"; shift 2 ;;
    --keep) keep="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --deploy) deploy="$2"; shift 2 ;;
    --rebuild-image) rebuild_image=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$release" =~ ^[1-9][0-9]*$ ]] || { echo "--release must be a positive integer" >&2; exit 2; }
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "--keep must be a positive integer" >&2; exit 2; }
for p in ${only//,/ }; do
  case "$p" in termoak|termoak-cli|termoak-server) ;; *) echo "unknown package: $p" >&2; exit 2 ;; esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && [ -r /root/.config/termoak/github-token ]; then
  token="$(cat /root/.config/termoak/github-token)"
fi
gh_api() {
  local auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# Latest published (not draft, not prerelease) release of a repo whose tag
# starts with a prefix, e.g. "server-v" -> 0.2.1.
latest_version() {
  local repo="$1" prefix="$2"
  gh_api "repos/$org/$repo/releases?per_page=100" | python3 -c '
import json, sys
prefix = sys.argv[1]
def key(v):
    return [int(x) if x.isdigit() else x for x in v.replace("-", ".").split(".")]
vs = [r["tag_name"][len(prefix):] for r in json.load(sys.stdin)
      if not r["draft"] and not r["prerelease"] and r["tag_name"].startswith(prefix)]
if not vs:
    sys.exit("no published release with prefix " + prefix)
print(max(vs, key=key))' "$prefix"
}

# Downloads a URL to a file unless it is already there.
fetch() {
  local url="$1" dst="$2"
  [ -s "$dst" ] && return
  mkdir -p "$(dirname "$dst")"
  curl -fsSL --retry 3 -o "$dst.part" "$url"
  mv "$dst.part" "$dst"
}

pkg_archs() {
  case "$1" in
    termoak) echo amd64 ;;
    *) echo amd64 arm64 ;;
  esac
}
up_arch() { case "$1" in amd64) echo x86_64 ;; arm64) echo aarch64 ;; esac; }

# True if every format of a package/version/arch is already in the staging repo.
in_repo() {
  local pkg="$1" ver="$2" arch="$3" ua
  ua="$(up_arch "$arch")"
  [ -f "$out/deb/pool/main/t/$pkg/${pkg}_${ver}-${release}_${arch}.deb" ] &&
    [ -f "$out/rpm/$ua/${pkg}-${ver}-${release}.$ua.rpm" ] &&
    [ -f "$out/arch/$ua/${pkg}-${ver}-${release}-$ua.pkg.tar.zst.sig" ]
}

# --- preflight -------------------------------------------------------------
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
GNUPGHOME="$gnupghome" gpg --batch --list-secret-keys "$fpr" >/dev/null 2>&1 ||
  { echo "signing key $fpr not found in $gnupghome" >&2; exit 1; }

mkdir -p "$out"
exec 9>"$out/../.publish.lock"
flock -n 9 || { echo "another publish.sh is running" >&2; exit 1; }

# A fresh staging directory starts from what is deployed, so the older
# versions kept in the pool survive.
if [ -n "$deploy" ] && [ ! -d "$out/deb/pool" ] && [ -d "$deploy/deb/pool" ]; then
  log "seeding $out from $deploy"
  rsync -a "$deploy"/ "$out"/
fi

if $rebuild_image || ! docker image inspect "$image" >/dev/null 2>&1; then
  log "building the $image image"
  docker build -q -t "$image" "$root/docker" >/dev/null
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/termoak-packages.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dl"
: >"$work/builds.txt"

# --- releases --------------------------------------------------------------
if $build; then
  for pkg in ${only//,/ }; do
    case "$pkg" in
      termoak) repo=desktop prefix=desktop-v ver="$want_desktop" ;;
      termoak-cli) repo=core prefix=cli-v ver="$want_cli" ;;
      termoak-server) repo=server prefix=server-v ver="$want_server" ;;
    esac
    [ -n "$ver" ] || ver="$(latest_version "$repo" "$prefix")"
    tag="$prefix$ver"
    base="https://github.com/$org/$repo/releases/download/$tag"
    raw="https://raw.githubusercontent.com/$org/$repo/$tag"
    for arch in $(pkg_archs "$pkg"); do
      if in_repo "$pkg" "$ver" "$arch"; then
        log "$pkg $ver-$release $arch: already in the repository"
        continue
      fi
      ua="$(up_arch "$arch")"
      d="$work/dl/$pkg-$ver-$arch"
      mkdir -p "$d/extra"
      case "$pkg" in
        termoak)
          fetch "$base/termoak-desktop-v$ver-linux-$ua.tar.gz" "$d/release.tar.gz"
          fetch "$raw/assets/icon.svg" "$d/extra/icon.svg"
          ;;
        termoak-cli)
          fetch "$base/termoak-cli-v$ver-linux-$ua.tar.gz" "$d/release.tar.gz"
          ;;
        termoak-server)
          fetch "$base/termoak-server-v$ver-linux-$ua.tar.gz" "$d/release.tar.gz"
          fetch "$raw/deploy/termoak-sessions.service" "$d/extra/termoak-sessions.service"
          ;;
      esac
      log "downloaded $pkg $ver $arch"
      tar -xzf "$d/release.tar.gz" -C "$d"
      rm "$d/release.tar.gz"
      echo "$pkg $ver $arch" >>"$work/builds.txt"
    done
  done
fi

# --- build, sign and index (in the container) ------------------------------
log "building in $image"
docker run --rm \
  -v "$root:/src:ro" \
  -v "$work:/work" \
  -v "$(cd "$out" && pwd):/repo" \
  -v "$gnupghome:/gnupg:ro" \
  -e FPR="$fpr" -e KEEP="$keep" -e PKG_RELEASE="$release" \
  "$image" bash /src/scripts/build-repo.sh

log "staging repository: $out"

# --- deploy ----------------------------------------------------------------
if [ -n "$deploy" ]; then
  [ -d "$deploy" ] || { echo "$deploy does not exist" >&2; exit 1; }
  log "deploying to $deploy"
  # Packages first, then the metadata that points to them; files no longer
  # in the staging repository are removed at the end.
  rsync -a --include='*/' --include='*.deb' --include='*.rpm' \
    --include='*.pkg.tar.zst' --include='*.pkg.tar.zst.sig' --exclude='*' \
    "$out"/ "$deploy"/
  rsync -a --delete-after --delay-updates "$out"/ "$deploy"/
  log "deployed"
fi
