#!/usr/bin/env bash
# Builds the packages and regenerates the APT, RPM and pacman repositories.
# Runs INSIDE the termoak-packaging container (docker/Dockerfile); start it
# with scripts/publish.sh, which downloads the releases and mounts:
#   /src    this repository (read-only)
#   /work   scratch: builds.txt and the extracted releases in dl/
#   /repo   the staging repository (output)
#   /gnupg  GNUPGHOME with the signing key (read-only)
# Environment: FPR (signing key fingerprint), KEEP (versions kept per
# package), PKG_RELEASE (package release of the packages built now),
# FDROID_FPR (SHA-256 of the F-Droid index certificate, for the index page),
# SITE_ONLY=1 (only regenerate the index page: scripts/publish.sh --only
# fdroid or flatpak).
set -euo pipefail
shopt -s inherit_errexit

SRC=/src
WORK=/work
REPO=/repo
: "${FPR:?}" "${KEEP:=3}" "${PKG_RELEASE:=1}"
export GNUPGHOME=/gnupg
# rpmsign warns when it cannot take GPG_TTY from stdin; there is no pinentry.
export GPG_TTY=/dev/null

GPG=(gpg --batch --yes --lock-never --no-auto-check-trustdb --no-permission-warning
  --digest-algo SHA512 --local-user "$FPR")

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# Package file names, per format.
deb_arch() { echo "$1"; }
rpm_arch() { case "$1" in amd64) echo x86_64 ;; arm64) echo aarch64 ;; esac; }
pac_arch() { rpm_arch "$1"; }
deb_path() { echo "$REPO/deb/pool/main/t/$1/${1}_${2}-${3}_$(deb_arch "$4").deb"; }
rpm_path() { echo "$REPO/rpm/$(rpm_arch "$4")/${1}-${2}-${3}.$(rpm_arch "$4").rpm"; }
pac_path() { echo "$REPO/arch/$(pac_arch "$4")/${1}-${2}-${3}-$(pac_arch "$4").pkg.tar.zst"; }

# Newest GLIBC_x.y symbol version a binary needs.
glibc_min() {
  readelf -V "$1" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n1
}

# Debian copyright file (DEP-5) with the full AGPL text (Debian has no
# common-licenses copy of it).
write_copyright() {
  local repo_name="$1" out="$2"
  {
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: Termoak"
    echo "Upstream-Contact: Ohz Digital SL <packages@termoak.com>"
    echo "Source: https://github.com/TermoakSSH/$repo_name"
    echo
    echo "Files: *"
    echo "Copyright: Ohz Digital SL"
    echo "License: AGPL-3.0-only"
    echo
    echo "License: AGPL-3.0-only"
    sed -e 's/^[[:space:]]*$/./' -e 's/^/ /' "$SRC/LICENSE"
  } >"$out"
}

# Fills the staging directory nfpm reads for one package/version/arch.
stage() {
  local pkg="$1" ver="$2" arch="$3" in="$4" st="$5"
  rm -rf "$st"
  mkdir -p "$st"
  cp "$SRC/LICENSE" "$st/LICENSE"
  case "$pkg" in
    termoak)
      write_copyright desktop "$st/copyright"
      install -m 755 "$in/termoak-desktop" "$st/termoak-desktop"
      install -m 644 "$SRC/files/termoak/com.termoak.Termoak.desktop" "$st/"
      mkdir -p "$st/icons"
      install -m 644 "$in/extra/icon.svg" "$st/icons/termoak.svg"
      for s in 16 24 32 48 64 128 256 512; do
        mkdir -p "$st/icons/$s"
        rsvg-convert -w "$s" -h "$s" "$in/extra/icon.svg" -o "$st/icons/$s/termoak.png"
      done
      echo "$st/termoak-desktop"
      ;;
    termoak-cli)
      write_copyright core "$st/copyright"
      install -m 755 "$in"/termoak-cli-*/termoak "$st/termoak"
      install -m 644 "$in"/termoak-cli-*/README.md "$st/README.md"
      echo "$st/termoak"
      ;;
    termoak-server)
      write_copyright server "$st/copyright"
      local d
      d="$(echo "$in"/termoak-server-*/)"
      install -m 755 "$d/termoak-server" "$st/termoak-server"
      install -m 644 "$d/README.md" "$st/README.md"
      install -m 644 "$d/config.example.toml" "$st/config.example.toml"
      # /etc/termoak/config.toml: the example with the packaged paths and the
      # session holder enabled (its unit ships in this package).
      sed -e 's|^data_dir = .*|data_dir = "/var/lib/termoak"|' \
        -e 's|^# holder_socket = |holder_socket = |' \
        "$d/config.example.toml" >"$st/config.toml"
      grep -q '^data_dir = "/var/lib/termoak"' "$st/config.toml"
      grep -q '^holder_socket = ' "$st/config.toml"
      # Units: the server one from the release tarball, the session holder
      # from the server repo at the same tag; binary moved to /usr/bin.
      sed 's|/usr/local/bin/termoak-server|/usr/bin/termoak-server|g' \
        "$d/termoak-server.service" >"$st/termoak-server.service"
      sed 's|/usr/local/bin/termoak-server|/usr/bin/termoak-server|g' \
        "$in/extra/termoak-sessions.service" >"$st/termoak-sessions.service"
      if grep -q /usr/local/ "$st"/*.service; then
        echo "warning: the units still mention /usr/local:" >&2
        grep -n /usr/local/ "$st"/*.service >&2
      fi
      install -m 644 "$SRC/files/termoak-server/sysusers.conf" "$st/sysusers.conf"
      install -m 644 "$SRC/files/termoak-server/tmpfiles.conf" "$st/tmpfiles.conf"
      cp -r "$SRC/files/termoak-server/scripts" "$st/scripts"
      echo "$st/termoak-server"
      ;;
  esac
}

# RPM requirements of an ELF binary, the way rpm's elfdeps writes them:
# every NEEDED soname and every symbol version used from it, e.g.
# libm.so.6(GLIBC_2.35)(64bit). (A plain glibc version is not enough: RHEL 9
# backports GLIBC_2.35 in libc.so.6 but not in libm.so.6.)
elf_requires() {
  {
    readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1()(64bit)/p'
    readelf -V "$1" | awk '
      /File: / { for (i = 1; i <= NF; i++) if ($i == "File:") file = $(i + 1) }
      /Name: / { for (i = 1; i <= NF; i++) if ($i == "Name:") v = $(i + 1)
                 if (file != "" && v !~ /PRIVATE/) print file "(" v ")(64bit)" }'
  } | sort -u
}

# nfpm config for one format: the line "- @ELF_REQUIRES@" becomes the
# binary's requirements and, for pacman (which shows `pkgdesc` as a one-line
# summary), the description keeps only its first line.
render_config() {
  local src="$1" format="$2" bin="$3"
  ELF_REQUIRES="$(elf_requires "$bin")" FORMAT="$format" awk '
    /^ *- "?@ELF_REQUIRES@"?$/ {
      indent = $0; sub(/-.*/, "", indent)
      n = split(ENVIRON["ELF_REQUIRES"], reqs, "\n")
      for (i = 1; i <= n; i++) if (reqs[i] != "") print indent "- \"" reqs[i] "\""
      next
    }
    ENVIRON["FORMAT"] == "archlinux" && /^description: \|-?$/ {
      getline; sub(/^ +/, ""); print "description: \"" $0 "\""; skip = 1; next
    }
    skip && /^  / { next }
    { skip = 0; print }
  ' "$src"
}

build_one() {
  local pkg="$1" ver="$2" arch="$3"
  local deb rpm pac
  deb="$(deb_path "$pkg" "$ver" "$PKG_RELEASE" "$arch")"
  rpm="$(rpm_path "$pkg" "$ver" "$PKG_RELEASE" "$arch")"
  pac="$(pac_path "$pkg" "$ver" "$PKG_RELEASE" "$arch")"
  if [ -f "$deb" ] && [ -f "$rpm" ] && [ -f "$pac" ] && [ -f "$pac.sig" ]; then
    log "$pkg $ver-$PKG_RELEASE $arch: already in the repository"
    return
  fi
  local in="$WORK/dl/$pkg-$ver-$arch" st="$WORK/stage/$pkg-$ver-$arch" bin out
  bin="$(stage "$pkg" "$ver" "$arch" "$in" "$st")"
  out="$WORK/out/$pkg-$ver-$arch"
  rm -rf "$out"
  mkdir -p "$out"
  export PKG_ARCH="$arch" PKG_VERSION="$ver" PKG_RELEASE GLIBC_MIN
  GLIBC_MIN="$(glibc_min "$bin")"
  log "$pkg $ver-$PKG_RELEASE $arch (glibc >= $GLIBC_MIN)"
  (
    cd "$st"
    if [ ! -f "$deb" ]; then
      render_config "$SRC/nfpm/$pkg.yaml" deb "$bin" >"$out/nfpm-deb.yaml"
      nfpm pkg -f "$out/nfpm-deb.yaml" -p deb -t "$out/$(basename "$deb")" >/dev/null
      mkdir -p "$(dirname "$deb")"
      mv "$out/$(basename "$deb")" "$deb"
    fi
    if [ ! -f "$rpm" ]; then
      render_config "$SRC/nfpm/$pkg.yaml" rpm "$bin" >"$out/nfpm-rpm.yaml"
      nfpm pkg -f "$out/nfpm-rpm.yaml" -p rpm -t "$out/$(basename "$rpm")" >/dev/null
      rpmsign --addsign \
        --define "_gpg_name $FPR" \
        --define "_openpgp_sign_id $FPR" \
        --define "_gpg_sign_cmd_extra_args --batch --lock-never --no-auto-check-trustdb --no-permission-warning" \
        "$out/$(basename "$rpm")" >/dev/null
      mkdir -p "$(dirname "$rpm")"
      mv "$out/$(basename "$rpm")" "$rpm"
    fi
    if [ ! -f "$pac" ] || [ ! -f "$pac.sig" ]; then
      render_config "$SRC/nfpm/$pkg.yaml" archlinux "$bin" >"$out/nfpm-archlinux.yaml"
      nfpm pkg -f "$out/nfpm-archlinux.yaml" -p archlinux -t "$out/$(basename "$pac")" >/dev/null
      "${GPG[@]}" --detach-sign --no-armor -o "$out/$(basename "$pac").sig" "$out/$(basename "$pac")"
      mkdir -p "$(dirname "$pac")"
      mv "$out/$(basename "$pac").sig" "$pac.sig"
      mv "$out/$(basename "$pac")" "$pac"
    fi
  )
  rm -rf "$out" "$st"
}

# Keeps the newest $KEEP versions of each package/arch in every format.
prune() {
  local pkg files n
  for pkg in termoak termoak-cli termoak-server; do
    for files in \
      "$REPO/deb/pool/main/t/$pkg/${pkg}_*_amd64.deb" \
      "$REPO/deb/pool/main/t/$pkg/${pkg}_*_arm64.deb" \
      "$REPO/rpm/x86_64/${pkg}-[0-9]*.x86_64.rpm" \
      "$REPO/rpm/aarch64/${pkg}-[0-9]*.aarch64.rpm" \
      "$REPO/arch/x86_64/${pkg}-[0-9]*-x86_64.pkg.tar.zst" \
      "$REPO/arch/aarch64/${pkg}-[0-9]*-aarch64.pkg.tar.zst"; do
      # shellcheck disable=SC2086 # the pattern must be expanded here
      mapfile -t list < <(ls -1 $files 2>/dev/null | sort -V)
      n=${#list[@]}
      if [ "$n" -gt "$KEEP" ]; then
        for f in "${list[@]:0:n-KEEP}"; do
          log "pruning $(basename "$f")"
          rm -f "$f" "$f.sig"
        done
      fi
    done
  done
}

apt_repo() {
  log "APT metadata"
  cd "$REPO/deb"
  rm -rf dists
  local a
  for a in amd64 arm64; do
    local d="dists/stable/main/binary-$a"
    mkdir -p "$d"
    apt-ftparchive --arch "$a" packages pool/main >"$d/Packages"
    gzip -9nk "$d/Packages"
    xz -9k "$d/Packages"
    cat >"$d/Release" <<EOF
Archive: stable
Suite: stable
Codename: stable
Origin: Termoak
Label: Termoak
Component: main
Architecture: $a
EOF
  done
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Termoak \
    -o APT::FTPArchive::Release::Label=Termoak \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="Termoak packages (https://pkg.termoak.com)" \
    release dists/stable >"$WORK/Release"
  mv "$WORK/Release" dists/stable/Release
  "${GPG[@]}" --clearsign -o dists/stable/InRelease dists/stable/Release
  "${GPG[@]}" --detach-sign --armor -o dists/stable/Release.gpg dists/stable/Release
}

rpm_repo() {
  log "RPM metadata"
  local a
  for a in x86_64 aarch64; do
    mkdir -p "$REPO/rpm/$a"
    # gzip metadata: readable by every dnf/zypper (zstd is not, on older ones).
    createrepo_c --quiet --update --general-compress-type=gz "$REPO/rpm/$a" >/dev/null
    "${GPG[@]}" --detach-sign --armor -o "$REPO/rpm/$a/repodata/repomd.xml.asc" \
      "$REPO/rpm/$a/repodata/repomd.xml"
    gpg --batch --lock-never --armor --export "$FPR" >"$REPO/rpm/$a/repodata/repomd.xml.key"
  done
  cat >"$REPO/rpm/termoak.repo" <<'EOF'
[termoak]
name=Termoak
baseurl=https://pkg.termoak.com/rpm/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkg.termoak.com/termoak.asc
EOF
}

arch_repo() {
  log "pacman metadata"
  local a
  for a in x86_64 aarch64; do
    local d="$REPO/arch/$a"
    mkdir -p "$d"
    rm -f "$d"/termoak.db* "$d"/termoak.files*
    mapfile -t pkgs < <(ls -1 "$d"/*.pkg.tar.zst 2>/dev/null | sort -V)
    [ "${#pkgs[@]}" -gt 0 ] || continue
    # In version order: the database keeps the last one added per package.
    (cd "$d" && repo-add --quiet termoak.db.tar.zst "${pkgs[@]##*/}" >/dev/null)
    "${GPG[@]}" --detach-sign --no-armor -o "$d/termoak.db.tar.zst.sig" "$d/termoak.db.tar.zst"
    "${GPG[@]}" --detach-sign --no-armor -o "$d/termoak.files.tar.zst.sig" "$d/termoak.files.tar.zst"
    ln -sf termoak.db.tar.zst.sig "$d/termoak.db.sig"
    ln -sf termoak.files.tar.zst.sig "$d/termoak.files.sig"
    rm -f "$d"/*.old "$d"/*.old.sig
  done
}

# Versions table for the index page (newest version of each package).
versions_table() {
  local pkg a f v archs
  for pkg in termoak termoak-cli termoak-server; do
    v=""
    archs=""
    for a in amd64 arm64; do
      f="$(ls -1 "$REPO/deb/pool/main/t/$pkg/${pkg}"_*_"$a".deb 2>/dev/null | sort -V | tail -n1 || true)"
      [ -n "$f" ] || continue
      archs="$archs${archs:+, }$a"
      v="$(basename "$f" | cut -d_ -f2)"
    done
    [ -n "$v" ] || continue
    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$pkg" "$v" "$archs"
  done
  # Flatpak: the version last built into the Flatpak repository.
  if [ -s "$REPO/flatpak/VERSION" ] && [ -d "$REPO/flatpak/repo/objects" ]; then
    printf '<tr><td><a href="#flatpak">com.termoak.Termoak</a> (Flatpak)</td><td>%s</td><td>x86_64</td></tr>\n' \
      "$(head -n1 "$REPO/flatpak/VERSION")"
  fi
  # Android: the newest version in the F-Droid repository.
  v="$(android_version)"
  if [ -n "$v" ]; then
    printf '<tr><td><a href="#fdroid">Android (F-Droid)</a></td><td>%s</td><td>arm64-v8a, armeabi-v7a</td></tr>\n' "$v"
  fi
}

# Newest Android version in the F-Droid repository (from the APK names).
android_version() {
  ls -1 "$REPO"/fdroid/repo/Termoak-android-v*.apk 2>/dev/null |
    sed -n 's|.*/Termoak-android-v\([0-9][^-]*\)\(-[a-z0-9-]*\)\{0,1\}\.apk$|\1|p' |
    sort -uV | tail -n1 || true
}

site() {
  log "keys and index.html"
  gpg --batch --lock-never --armor --export "$FPR" >"$REPO/termoak.asc"
  gpg --batch --lock-never --export "$FPR" >"$REPO/termoak.gpg"
  local spaced table
  spaced="$(echo "$FPR" | sed -E 's/(.{4})/\1 /g; s/ $//; s/^((.{4} ){5})/\1 /')"
  table="$(versions_table)"
  # F-Droid: the fingerprint as clients show it (AA:BB:...) and as the
  # repository link takes it (no separators).
  local ffpr fspaced
  ffpr="$(echo "${FDROID_FPR:-}" | tr -d ': ' | tr 'a-f' 'A-F')"
  fspaced="$(echo "$ffpr" | sed -E 's/(..)/\1:/g; s/:$//')"
  FPR="$FPR" SPACED="$spaced" TABLE="$table" UPDATED="$(date -u +%Y-%m-%d)" \
    FFPR="$ffpr" FSPACED="$fspaced" \
    awk '{
      gsub(/@FINGERPRINT@/, ENVIRON["FPR"]);
      gsub(/@FINGERPRINT_SPACED@/, ENVIRON["SPACED"]);
      gsub(/@FDROID_FINGERPRINT@/, ENVIRON["FFPR"]);
      gsub(/@FDROID_FINGERPRINT_SPACED@/, ENVIRON["FSPACED"]);
      gsub(/@UPDATED@/, ENVIRON["UPDATED"]);
      if ($0 ~ /@VERSIONS@/) { print ENVIRON["TABLE"]; next }
      print
    }' "$SRC/site/index.html" >"$REPO/index.html"
}

mkdir -p "$REPO" "$WORK/stage" "$WORK/out"
if [ "${SITE_ONLY:-0}" != 1 ]; then
  if [ -s "$WORK/builds.txt" ]; then
    while read -r pkg ver arch; do
      [ -n "$pkg" ] || continue
      build_one "$pkg" "$ver" "$arch"
    done <"$WORK/builds.txt"
  fi
  prune
  apt_repo
  rpm_repo
  arch_repo
fi
site
log "repository ready"
