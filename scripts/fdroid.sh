#!/usr/bin/env bash
# Updates the F-Droid repository (https://pkg.termoak.com/fdroid/repo) in the
# staging tree: downloads the APKs of the newest published Android releases
# (android-vX.Y.Z in TermoakSSH/mobile-android), drops the older ones and
# regenerates the index, signed with the repository's own key, in the
# termoak-fdroid Docker image (docker/fdroid.Dockerfile, built on first use).
# The APKs are published as they are on GitHub, with the app's signature:
# nothing is rebuilt or re-signed.
#
# Usually run by scripts/publish.sh (which also deploys); on its own:
#   scripts/fdroid.sh [options]
#   --keep N          Android releases kept (default 3)
#   --no-build        download nothing; only regenerate the index
#   --out DIR         staging tree (default: <repo>/out/repo); the F-Droid
#                     repository goes to DIR/fdroid/repo
#   --rebuild-image   rebuild the termoak-fdroid image first
#   --verify-remote   only check the published repository: downloads the
#                     index from https://pkg.termoak.com/fdroid/repo with
#                     fdroidserver's client code (signature and fingerprint
#                     checked) and that every APK is served with its size
#                     (scripts/publish.sh runs it after --deploy)
#
# Environment: TERMOAK_FDROID_KEYS (default /root/.config/termoak/fdroid:
# keystore.p12, keystore.pass), TERMOAK_FDROID_FINGERPRINT (SHA-256 of the
# index signing certificate), TERMOAK_APP_SIGNER (SHA-256 of the app's
# signing certificate), GITHUB_TOKEN (default: the contents of
# /root/.config/termoak/github-token when readable).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image=termoak-fdroid
keys="${TERMOAK_FDROID_KEYS:-/root/.config/termoak/fdroid}"
repo_fpr="${TERMOAK_FDROID_FINGERPRINT:-CB2FCCB0151AE3632E0578364B75CD7357FF5A09E6CB9F3624FAA22628A7C621}"
app_signer="${TERMOAK_APP_SIGNER:-392C208A05FB966C38FA36D3853FB80EDD4739D28DFD1D27EA7EBA68FC1F4748}"
gh_repo=TermoakSSH/mobile-android

keep=3 build=true rebuild_image=false verify_remote=false
out="$root/out/repo"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep="$2"; shift 2 ;;
    --no-build) build=false; shift ;;
    --out) out="$2"; shift 2 ;;
    --rebuild-image) rebuild_image=true; shift ;;
    --verify-remote) verify_remote=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "--keep must be a positive integer" >&2; exit 2; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is required"

ensure_image() {
  if $rebuild_image || ! docker image inspect "$image" >/dev/null 2>&1; then
    log "building the $image image"
    docker build -q -t "$image" -f "$root/docker/fdroid.Dockerfile" "$root/docker" >/dev/null
    rebuild_image=false
  fi
}

if $verify_remote; then
  ensure_image
  log "checking https://pkg.termoak.com/fdroid/repo"
  docker run --rm -w /tmp -e REPO_FPR="$repo_fpr" -e APP_SIGNER="$app_signer" "$image" python3 -c '
import os, urllib.request
from fdroidserver import common, index
common.config = common.read_config()
base = "https://pkg.termoak.com/fdroid/repo"
fpr, signer = os.environ["REPO_FPR"].upper(), os.environ["APP_SIGNER"].lower()
# Raises unless entry.jar is signed by the key with this fingerprint and
# index-v2.json matches the hash in entry.json.
data, _ = index.download_repo_index_v2(base + "?fingerprint=" + fpr)
index.download_repo_index_v1(base + "?fingerprint=" + fpr)
versions = data["packages"]["com.termoak"]["versions"].values()
for v in sorted(versions, key=lambda v: -v["manifest"]["versionCode"]):
    m, f = v["manifest"], v["file"]
    assert m["signer"]["sha256"] == [signer], m["signer"]
    req = urllib.request.Request(base + f["name"], method="HEAD")
    with urllib.request.urlopen(req) as r:
        size = int(r.headers["Content-Length"])
    assert r.status == 200 and size == f["size"], (f["name"], r.status, size, f["size"])
    print("  ok", m["versionName"], m["versionCode"], f["name"].lstrip("/"), size)
print("  index-v1.jar, entry.jar and index-v2.json verified with fingerprint", fpr)
' 2>&1 | grep -v '^WARNING'
  exit "${PIPESTATUS[0]}"
fi
[ -r "$keys/keystore.p12" ] && [ -r "$keys/keystore.pass" ] ||
  die "the F-Droid index keystore is missing in $keys (keystore.p12, keystore.pass)"

mkdir -p "$out/fdroid/repo" "$root/out/fdroid"
out="$(cd "$out" && pwd)"
repo="$out/fdroid/repo"
work="$root/out/fdroid"   # fdroid's working directory (APK cache in tmp/)

token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && [ -r /root/.config/termoak/github-token ]; then
  token="$(tr -d '[:space:]' </root/.config/termoak/github-token)"
fi

# --- APKs --------------------------------------------------------------------
if $build; then
  auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  # "<file> <size> <sha256> <url>" for the APKs of the newest $keep published
  # android-v* releases (drafts and prereleases ignored; X.Y.Z-pre sorts
  # before X.Y.Z).
  list="$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$gh_repo/releases?per_page=100" | python3 -c '
import json, re, sys
keep = int(sys.argv[1])
def key(v):
    core, _, pre = v.partition("-")
    nums = [int(x) if x.isdigit() else 0 for x in core.split(".")]
    rest = [(0, int(x), "") if x.isdigit() else (1, 0, x) for x in pre.split(".")] if pre else []
    return (nums, 0 if pre else 1, rest)
rels = [r for r in json.load(sys.stdin)
        if not r["draft"] and not r["prerelease"] and r["tag_name"].startswith("android-v")]
rels.sort(key=lambda r: key(r["tag_name"][len("android-v"):]), reverse=True)
n = 0
for r in rels:
    v = r["tag_name"][len("android-v"):]
    apks = [a for a in r["assets"]
            if re.fullmatch(r"Termoak-android-v%s(-(arm64-v8a|armeabi-v7a|universal))?\.apk" % re.escape(v), a["name"])]
    if not apks:
        continue
    for a in apks:
        digest = (a.get("digest") or "").removeprefix("sha256:") or "-"
        print(a["name"], a["size"], digest, a["browser_download_url"])
    n += 1
    if n == keep:
        break
if n == 0:
    sys.exit("no published android-v* release with APKs")
' "$keep")"

  wanted=()
  while read -r name size digest url; do
    wanted+=("$name")
    dst="$repo/$name"
    # Already there: kept unless GitHub has a different file under that name
    # (an asset replaced in the release).
    if [ -f "$dst" ] && [ "$(stat -c %s "$dst")" = "$size" ] &&
      { [ "$digest" = - ] || [ "$(sha256sum <"$dst" | cut -d' ' -f1)" = "$digest" ]; }; then
      continue
    fi
    log "downloading $name"
    curl -fsSL --retry 3 -o "$dst.part" "$url"
    [ "$(stat -c %s "$dst.part")" = "$size" ] || die "$name: size differs from GitHub's"
    if [ "$digest" != - ]; then
      echo "$digest  $dst.part" | sha256sum -c --quiet - || die "$name: SHA-256 differs from GitHub's"
    fi
    mv "$dst.part" "$dst"
  done <<<"$list"

  for f in "$repo"/*.apk; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    if ! printf '%s\n' "${wanted[@]}" | grep -qxF "$name"; then
      log "dropping $name"
      rm -f "$f" "$f.asc" "$f.idsig"
    fi
  done
  log "APKs kept: ${#wanted[@]} (newest $keep releases)"
fi

# --- index (in the container) --------------------------------------------------
ensure_image

log "fdroid update in $image"
docker run --rm \
  -v "$root:/src:ro" \
  -v "$work:/fdroid" \
  -v "$repo:/fdroid/repo" \
  -v "$out/fdroid:/site" \
  -v "$keys:/keys:ro" \
  -e APP_SIGNER="$app_signer" -e REPO_FPR="$repo_fpr" \
  "$image" bash /src/scripts/build-fdroid.sh

log "F-Droid repository: $repo"
