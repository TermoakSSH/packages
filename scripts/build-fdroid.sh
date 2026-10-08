#!/usr/bin/env bash
# Regenerates and signs the F-Droid repository (index-v1, index-v2, entry).
# Runs INSIDE the termoak-fdroid container (docker/fdroid.Dockerfile); start
# it with scripts/fdroid.sh, which downloads the APKs and mounts:
#   /src           this repository (read-only)
#   /fdroid        fdroid's working directory (config.yml, metadata/, tmp/
#                  with the APK cache, so the "added" dates stay stable)
#   /fdroid/repo   the repository served at https://pkg.termoak.com/fdroid/repo
#                  (APKs already in place)
#   /site          the parent of repo/ in the staging tree: qr.svg goes there
#   /keys          the index signing keystore and its password (read-only)
# Environment: APP_SIGNER (SHA-256 of the app's signing certificate, every
# APK must be signed with it), REPO_FPR (SHA-256 of the index signing
# certificate, checked against the keystore).
set -euo pipefail
shopt -s inherit_errexit nullglob

: "${APP_SIGNER:?}" "${REPO_FPR:?}"
APP_ID=com.termoak
REPO_URL=https://pkg.termoak.com/fdroid/repo

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
lower() { tr 'A-F' 'a-f' | tr -d ': '; }

FDROID_KEYSTORE_PASS="$(head -n1 /keys/keystore.pass)"
export FDROID_KEYSTORE_PASS

# --- index signing key --------------------------------------------------------
cert_fpr="$(keytool -exportcert -keystore /keys/keystore.p12 -alias termoak-fdroid \
  -storepass:env FDROID_KEYSTORE_PASS | sha256sum | cut -d' ' -f1)"
[ "$cert_fpr" = "$(echo "$REPO_FPR" | lower)" ] ||
  die "the keystore's certificate is $cert_fpr, expected $REPO_FPR"

# --- working directory -------------------------------------------------------
cd /fdroid
umask 022
(umask 077 && cp /src/fdroid/config.yml config.yml)
rm -rf metadata
cp -r /src/fdroid/metadata metadata
cp /src/fdroid/metadata/$APP_ID/en-US/images/icon.png icon.png
mkdir -p tmp

# --- the APKs: the app's own signature only ----------------------------------
apks=(repo/*.apk)
[ ${#apks[@]} -gt 0 ] || die "no APKs in repo/"
want="$(echo "$APP_SIGNER" | lower)"
for apk in "${apks[@]}"; do
  out="$(apksigner verify --print-certs "$apk")" || die "$apk: invalid signature"
  signers="$(sed -n 's/^Signer #[0-9]* certificate SHA-256 digest: //p' <<<"$out" | sort -u)"
  [ "$signers" = "$want" ] || die "$apk is signed by $signers, not by $APP_SIGNER"
done
log "${#apks[@]} APKs, all signed by the app's key"

# --- index -------------------------------------------------------------------
log "fdroid update"
fdroid update
for f in index-v1.jar index-v1.json index-v2.json entry.jar entry.json; do
  [ -s "repo/$f" ] || die "fdroid update did not write repo/$f"
done

# --- checks --------------------------------------------------------------------
log "checking the index"
python3 - "$APP_ID" "$want" "$(echo "$REPO_FPR" | lower)" <<'EOF'
import hashlib, json, os, sys, zipfile
from fdroidserver import common, index

appid, app_signer, repo_fpr = sys.argv[1:]
common.read_config()
os.chdir("repo")

# entry.jar, index-v1.jar and index.jar: signed with the index key (the same
# check as the F-Droid client: the certificate in the JAR signature block).
# fdroid signs index-v1.jar and index.jar with SHA-1 digests on purpose, for
# old clients: modern jarsigner only accepts them in "deprecated" mode.
for jar in ("entry.jar", "index-v1.jar", "index.jar"):
    with zipfile.ZipFile(jar) as z:
        blocks = [n for n in z.namelist() if n.startswith("META-INF/") and n.endswith((".RSA", ".DSA", ".EC"))]
        assert len(blocks) == 1, (jar, blocks)
        cert = common.get_certificate(z.read(blocks[0]))
    fpr = hashlib.sha256(cert).hexdigest()
    assert fpr == repo_fpr, (jar, fpr)
    # Raises if the signature does not verify.
    if jar == "entry.jar":
        common.verify_jar_signature(jar)
    else:
        common.verify_deprecated_jar_signature(jar)

# entry.json points to this index-v2.json.
entry = json.load(open("entry.json"))
v2 = entry["index"]
data = open("index-v2.json", "rb").read()
assert v2["name"] == "/index-v2.json", v2
assert v2["size"] == len(data), (v2["size"], len(data))
assert v2["sha256"] == hashlib.sha256(data).hexdigest()

idx = json.loads(data)
assert idx["repo"]["address"] == "https://pkg.termoak.com/fdroid/repo", idx["repo"]["address"]
pkgs = idx["packages"]
assert list(pkgs) == [appid], list(pkgs)
versions = pkgs[appid]["versions"]
apks = sorted(f for f in os.listdir(".") if f.endswith(".apk"))
assert sorted(v["file"]["name"].lstrip("/") for v in versions.values()) == apks
for v in sorted(versions.values(), key=lambda v: -v["manifest"]["versionCode"]):
    name = v["file"]["name"].lstrip("/")
    m = v["manifest"]
    assert v["file"]["size"] == os.path.getsize(name), name
    assert v["file"]["sha256"] == hashlib.sha256(open(name, "rb").read()).hexdigest(), name
    assert m["signer"]["sha256"] == [app_signer], (name, m["signer"])
    print(f"  {m['versionName']:>8}  {m['versionCode']:>6}  {','.join(m.get('nativecode', [])):<24} {name}")
meta = pkgs[appid]["metadata"]
print("  name:", meta["name"], "| summary (en-US):", meta["summary"]["en-US"])
print("  categories:", ", ".join(meta.get("categories", [])), "| license:", meta.get("license"))
print("  icon:", meta.get("icon", {}).get("en-US", {}).get("name"))
EOF

# --- QR code for the index page ------------------------------------------------
link="$REPO_URL?fingerprint=$(echo "$REPO_FPR" | lower | tr 'a-f' 'A-F')"
qrencode -t SVG --svg-path --margin 2 --size 6 --level M -o /site/qr.svg "$link"
qrencode -t PNG --margin 2 --size 8 --level M -o /site/qr.png "$link"
log "repository ready: $link"
