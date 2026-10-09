# Termoak packages

Packaging and signed repositories for [Termoak](https://termoak.com), served
at **https://pkg.termoak.com**: APT, RPM, pacman and a
[Flatpak repository](#linux-flatpak) for Linux, and an
[F-Droid repository](#android-f-droid) for Android.

| Package          | Contents                                                        | Architectures  |
|------------------|-----------------------------------------------------------------|----------------|
| `termoak`        | Desktop app: `/usr/bin/termoak-desktop`, desktop entry, icons    | amd64          |
| `termoak-cli`    | Command-line client: `/usr/bin/termoak`                         | amd64, arm64   |
| `termoak-server` | Server, `/etc/termoak/config.toml`, systemd units, `termoak` user | amd64, arm64   |

The packages are built from the binaries of the published GitHub releases
(`desktop-v*` in [desktop](https://github.com/TermoakSSH/desktop), `cli-v*` in
[core](https://github.com/TermoakSSH/core), `server-v*` in
[server](https://github.com/TermoakSSH/server)); nothing is compiled here.
Formats: `.deb` (APT), `.rpm` (dnf and zypper) and `.pkg.tar.zst` (pacman).
The Android app (`com.termoak`) goes to the F-Droid repository as the APKs of
the `android-v*` releases of
[mobile-android](https://github.com/TermoakSSH/mobile-android), unchanged.

User-facing install instructions are on the index page of the repository,
generated from [`site/index.html`](site/index.html).

## Layout

```
docker/Dockerfile          tool image (Fedora): nfpm, apt-ftparchive, createrepo_c,
                           rpmsign, repo-add, gpg, rsvg-convert
docker/fdroid.Dockerfile   F-Droid tool image (Debian 13): fdroidserver, apksigner,
                           qrencode
docker/flatpak.Dockerfile  Flatpak tool image (Debian 13): flatpak, flatpak-builder,
                           appstream, flatpak-cargo-generator, Xvfb
nfpm/<package>.yaml        nfpm configuration of each package
files/termoak/             desktop entry (com.termoak.Termoak.desktop)
files/termoak-server/      sysusers.d / tmpfiles.d snippets and maintainer scripts
fdroid/config.yml          fdroidserver configuration of the F-Droid repository
fdroid/metadata/           com.termoak.yml and com.termoak/<locale>/ (fastlane
                           layout: texts, icon, screenshots)
site/index.html            template of the repository index page (en + es)
scripts/publish.sh         downloads releases, builds, signs, regenerates the repos
scripts/build-repo.sh      the part of publish.sh that runs inside the tool image
scripts/fdroid.sh          updates the F-Droid repository (called by publish.sh)
scripts/build-fdroid.sh    the part of fdroid.sh that runs inside the F-Droid image
scripts/flatpak.sh         builds the Flatpak and updates its repository (called by publish.sh)
scripts/build-flatpak.sh   the part of flatpak.sh that runs inside the Flatpak image
scripts/test-repo.sh       installs from the staging repo in distro containers
tests/                     the per-distro test scripts used by test-repo.sh
docs/fdroid/               draft for the official F-Droid repository (fdroiddata)
docs/flathub/              steps and status of the Flathub submission
```

Published layout (`out/repo` by default, then the web root):

```
index.html  termoak.asc  termoak.gpg
deb/dists/stable/{InRelease,Release,Release.gpg}
deb/dists/stable/main/binary-{amd64,arm64}/Packages{,.gz,.xz}
deb/pool/main/t/<package>/<package>_<version>-<release>_<arch>.deb
rpm/termoak.repo
rpm/{x86_64,aarch64}/*.rpm
rpm/{x86_64,aarch64}/repodata/{repomd.xml,repomd.xml.asc,repomd.xml.key,...}
arch/{x86_64,aarch64}/*.pkg.tar.zst{,.sig}
arch/{x86_64,aarch64}/termoak.{db,files}{,.sig} -> termoak.{db,files}.tar.zst{,.sig}
fdroid/qr.svg  fdroid/qr.png                        QR code of the repository link
fdroid/repo/{entry.jar,entry.json,index-v2.json,index-v1.jar,index-v1.json,diff/}
fdroid/repo/Termoak-android-v<version>-{arm64-v8a,armeabi-v7a,universal}.apk
fdroid/repo/{com.termoak/,icons*/,index.html,index.png,status/...}  (fdroidserver)
flatpak/termoak.flatpakrepo  flatpak/com.termoak.Termoak.flatpakref
flatpak/termoak.svg  flatpak/VERSION                 icon of the repo; version last built
flatpak/repo/{config,summary,summary.sig,refs/,objects/,deltas/,...}  (OSTree, signed)
```

fdroid's working directory (generated `config.yml`, metadata copy, and
`tmp/` with the APK cache and the last indexes, which keep the "added" dates
stable and feed the index diffs) is `out/fdroid/`, outside the published
tree.

## Requirements

Only Docker, `curl`, `python3`, `rsync`, `flock` and `gpg` (to check that the
key is there) on the host. Everything else runs in the `termoak-packaging`
image, built from `docker/Dockerfile` the first time (about 470 MB; nfpm is
downloaded with a pinned SHA-256), and in the `termoak-fdroid` image, built
from `docker/fdroid.Dockerfile` (Debian 13 pinned by digest, fdroidserver
2.4.2, apksigner 35.0.2 and qrencode 4.1.1 pinned by version; about 2 GB on
disk, mostly the JDK). Nothing is built on GitHub Actions. On the shared
build host, run the scripts under the build lock:
`flock /root/.termoak-build.lock scripts/publish.sh ...`.

The signing key lives in `GNUPGHOME=/root/.config/termoak/repo-gpg` (RSA-4096,
sign-only, fingerprint `BDD6B45E003E53F1B9DE70932C813822C95C7F5B`). It is
mounted **read-only** into the container for signing and never copied; gpg
runs there with `--lock-never` and its agent socket under `/run/user/0`.

## Publishing

```sh
scripts/publish.sh                                   # latest releases -> out/repo
scripts/publish.sh --deploy /var/www/pkg.termoak.com # ... and copy to the web root
scripts/publish.sh --only fdroid --deploy /var/www/pkg.termoak.com  # Android only
```

What it does:

1. Resolves the latest published release of each component with the GitHub
   API (drafts and prereleases are ignored), or uses `--desktop`, `--cli`,
   `--server VERSION`.
2. Downloads the release tarballs, plus two files from the repository at the
   same tag: `assets/icon.svg` (desktop) and `deploy/termoak-sessions.service`
   (server). Packages already in the staging repository are skipped, so it is
   safe to run again: only the metadata and the index page are regenerated.
3. In the tool image: stages the files, builds `.deb`, `.rpm` and
   `.pkg.tar.zst` with nfpm, signs the RPMs (`rpmsign`, header signature
   RSA/SHA-512) and the pacman packages (detached `.sig`), keeps the newest
   `--keep` versions (default 3) of each package and arch, and regenerates:
   - APT: `Packages` with `apt-ftparchive`, `Release` signed as `InRelease`
     and `Release.gpg`; suite and codename `stable`, component `main`.
   - RPM: `createrepo_c` (gzip metadata, readable by older dnf/zypper),
     `repomd.xml.asc`, `repomd.xml.key` and `rpm/termoak.repo`.
   - pacman: `repo-add` (database and files lists, signed), packages added in
     version order so the database points to the newest one; older versions
     stay in the directory for `pacman -U`.
   - `termoak.asc` / `termoak.gpg` (exported from the keyring) and
     `index.html` with the current versions.
4. F-Droid and Flatpak (unless `--only` leaves them out):
   `scripts/fdroid.sh`, see [Android (F-Droid)](#android-f-droid), and
   `scripts/flatpak.sh`, see [Linux (Flatpak)](#linux-flatpak).
5. With `--deploy DIR`: rsync of the packages, APKs and Flatpak objects first and then of everything
   else with `--delete-after --delay-updates`, so clients never see metadata
   that points to missing files. **Files in DIR that are not in the staging
   repository are deleted.** If the staging directory is empty and DIR
   already holds a repository, the staging directory is first seeded from it,
   so the older versions in the pool are kept. When the F-Droid repository
   was updated and DIR is the web root, `scripts/fdroid.sh --verify-remote`
   then checks what https://pkg.termoak.com/fdroid/repo serves.

Other options: `--only termoak,termoak-cli,termoak-server,fdroid,flatpak`
(with only `fdroid` and/or `flatpak`, the APT/RPM/pacman metadata is not
touched), `--flatpak-ref REF`, `--flatpak-dir DIR`, `--no-build`,
`--release N`, `--keep N`, `--out DIR`, `--rebuild-image`. See
`scripts/publish.sh --help`.

### Package release

`--release N` (default 1) is the package release (`0.2.1-1`, `0.2.1-2`...).
Raise it to republish the same upstream version after a packaging change; a
version-release already in the repository is never rebuilt or overwritten.

### Backfilling an older version

```sh
scripts/publish.sh --only termoak --desktop 0.2.1
```

## Android (F-Droid)

Repository: **https://pkg.termoak.com/fdroid/repo**, signed with its own key
(not the app's): SHA-256 fingerprint

```
CB:2F:CC:B0:15:1A:E3:63:2E:05:78:36:4B:75:CD:73:57:FF:5A:09:E6:CB:9F:36:24:FA:A2:26:28:A7:C6:21
```

Users add it from the index page of pkg.termoak.com: the "Add to F-Droid"
link (`fdroidrepos://pkg.termoak.com/fdroid/repo?fingerprint=CB2FCCB0…C621`),
the QR code (`https://pkg.termoak.com/fdroid/repo?fingerprint=…`, which
F-Droid's scanner and its link handler accept), or by hand in F-Droid's
*Settings → Repositories → +* with the address and the fingerprint above,
which F-Droid checks against the index signature.

**What is published.** The APKs of the newest `--keep` (3) published
`android-v*` releases of TermoakSSH/mobile-android, downloaded from GitHub
(size and SHA-256 checked against the API's) and published **as they are**:
never rebuilt or re-signed. They keep the app's own signature (certificate
SHA-256 `39:2C:20:8A:05:FB:96:6C:38:FA:36:D3:85:3F:B8:0E:DD:47:39:D2:8D:FD:1D:27:EA:7E:BA:68:FC:1F:47:48`),
so F-Droid updates an install from GitHub and the other way round;
`build-fdroid.sh` refuses any APK signed by another key. Per version:
`arm64-v8a` (versionCode `10·base+2`), `armeabi-v7a` (`+1`) and `universal`
(`+0`). F-Droid handles split APKs: each has its `nativecode` in the index
and the client installs the highest compatible versionCode, i.e. the APK of
the device's ABI; the universal one is there for completeness (it is never
preferred, since the per-ABI APKs cover the same ABIs). Older releases are
removed from the repository (no archive section: `archive_older: 0`).

**Metadata.** `fdroid/metadata/com.termoak.yml` (license, links, categories,
anti-features) and `fdroid/metadata/com.termoak/<locale>/` in fastlane layout:
`title.txt`, `short_description.txt` (≤ 80 characters) and
`full_description.txt` for `en-US` and `es-ES` (the Play Store texts), and
`en-US/images/icon.png` (512 px, rendered from the app icon `icon.svg`).
Screenshots: put them in `<locale>/images/phoneScreenshots/` (`1.png`,
`2.png`... phone portrait; `en-US` is the fallback for other languages) and
publish again. Anti-features: none (the reasons are in `com.termoak.yml`).

**Index signing key.** `/root/.config/termoak/fdroid/` (0700): `keystore.p12`
(PKCS#12, RSA 4096, alias `termoak-fdroid`, valid until 2054,
`CN=Termoak F-Droid repository, O=Ohz Digital SL, C=ES`), `keystore.pass`
(its password) and `repo-cert.pem` (the public certificate), files 0600
except the certificate. Mounted read-only into the container; fdroid reads
the password from an environment variable (`fdroid/config.yml` has no
secrets). Keep a copy off this machine: with another key, every user would
have to remove and add the repository again. `scripts/fdroid.sh` checks the
keystore against the fingerprint above (`TERMOAK_FDROID_FINGERPRINT`).

**What `scripts/fdroid.sh` does** (also usable on its own: `--keep`,
`--no-build`, `--out`, `--rebuild-image`, `--verify-remote`):

1. Lists the releases with the GitHub API and downloads the missing APKs to
   `out/repo/fdroid/repo/`; drops the APKs of older releases.
2. In the `termoak-fdroid` image: checks every APK's signer with apksigner,
   runs `fdroid update` (index-v1, index-v2, entry, diffs, signed with the
   repository key), then parses the result: `entry.jar`, `index-v1.jar` and
   `index.jar` signed by the repository key, `entry.json` matching
   `index-v2.json`, one entry per APK with its size, SHA-256 and signer.
3. Writes `fdroid/qr.svg` and `qr.png` with qrencode for the index page.

`--verify-remote` downloads the published index with fdroidserver's own
client code (`index.download_repo_index_v2/v1`, which checks the JAR
signature against the fingerprint) and checks with `HEAD` that every APK is
served with its size.

**On each new Android release** (after `scripts/release-local.sh publish
android` in mobile-android):

```sh
flock /root/.termoak-build.lock scripts/publish.sh --only fdroid --deploy /var/www/pkg.termoak.com
```

Caddy serves the index files (`entry.jar`, `index-v1.jar`, `index-v2.json`,
`diff/`...) with `Cache-Control: no-cache` (block `pkg.termoak.com` in
`/etc/caddy/Caddyfile`); MIME types come from `/etc/mime.types`
(`application/java-archive`, `application/vnd.android.package-archive`).

**Official F-Droid repository.** A draft recipe for fdroiddata and the steps
are in [`docs/fdroid/`](docs/fdroid/README.md).

## Linux (Flatpak)

Repository: **https://pkg.termoak.com/flatpak/repo**, an OSTree repository
whose commits and summary are signed with the package key (fingerprint
`BDD6B45E…7F5B`). Users add it with
`flatpak remote-add --if-not-exists termoak https://pkg.termoak.com/flatpak/termoak.flatpakrepo`
and `flatpak install termoak com.termoak.Termoak` (the runtime,
`org.freedesktop.Platform//26.08`, comes from Flathub), or open
`flatpak/com.termoak.Termoak.flatpakref` in a software center. Branch
`stable`, x86_64.

**What is published.** The desktop app built **from source** by
flatpak-builder with the manifest of TermoakSSH/desktop
([`flatpak/`](https://github.com/TermoakSSH/desktop/tree/main/flatpak) on
`main`, or `--flatpak-ref`), which pins the release tag and vendors every
crate of its `Cargo.lock` (`cargo-sources.json`): the same manifest that is
prepared for Flathub ([docs/flathub](docs/flathub/README.md)). Unlike the
other packages, this is compiled here, not taken from the release binaries:
a release build with fat LTO, about 30 minutes with 2 jobs. The Flatpak
updates through `flatpak update`; the app's own updater is off inside the
sandbox.

**What `scripts/flatpak.sh` does** (also on its own: `--desktop-ref`,
`--desktop-dir`, `--out`, `--keep`, `--no-build`, `--no-smoke`, `--lint`,
`--rebuild-image`, `--verify-remote`):

1. Clones TermoakSSH/desktop at the ref (or uses `--desktop-dir`).
2. In the `termoak-flatpak` image, with bubblewrap allowed
   (`--cap-add SYS_ADMIN --cap-add NET_ADMIN` and seccomp, AppArmor and
   `systempaths` unconfined; not `--privileged`): `flatpak-builder --install-deps-from=flathub
   --disable-rofiles-fuse --repo=out/repo/flatpak/repo --gpg-sign=<key>`
   commits `app/com.termoak.Termoak/x86_64/stable` (plus the `.Locale` and
   `.Debug` refs), signed.
3. `flatpak build-update-repo --generate-static-deltas --prune
   --prune-depth=<keep>`: summary (signed, with the public key, title and
   homepage), the `appstream`/`appstream2` branches for software centers and
   static deltas; keeps `--keep` (3) commits per ref.
4. Writes `termoak.flatpakrepo` and `com.termoak.Termoak.flatpakref` (with
   `GPGKey=` the base64 of the binary public key, and `RuntimeRepo=` Flathub),
   `termoak.svg` and `VERSION` (for the index page).
5. Smoke test: adds the staging repository to the container's installation,
   installs the app, checks `termoak-desktop --version` and that the window
   starts under Xvfb (software Vulkan of the GL extension), and uninstalls
   it.
6. With `--lint`: Flathub's linter on the manifest and the repository.

`--verify-remote` (run by `publish.sh --deploy /var/www/pkg.termoak.com`)
checks the published repository as a user would, in a throwaway container:
`flatpak --user remote-add` of `https://pkg.termoak.com/flatpak/termoak.flatpakrepo`,
`flatpak --user install termoak com.termoak.Termoak` (signature checked with
the key of the `.flatpakrepo`), `termoak-desktop --version`, and the MIME
types of the `.flatpakrepo` and `.flatpakref`.

The runtimes, the SDK, the GL extensions and org.flatpak.Builder (about
5 GB) and flatpak-builder's downloads and cache are kept in
`out/flatpak-cache/` between runs; delete it to free the space (the next
build downloads them again).

**On each new desktop release** (after updating the tag in the desktop
repository's `flatpak/com.termoak.Termoak.yml`, see its README):

```sh
flock /root/.termoak-build.lock scripts/publish.sh --only flatpak --deploy /var/www/pkg.termoak.com
```

Caddy serves `.flatpakrepo` and `.flatpakref` as
`application/vnd.flatpak.repo` and `application/vnd.flatpak.ref`, and the
OSTree `config`, `summary*` and `refs/` with `Cache-Control: no-cache`
(block `pkg.termoak.com` in `/etc/caddy/Caddyfile`).

## Package details

**Dependencies.** Read from the binaries with `readelf`:

- `termoak-cli` and `termoak-server` link only glibc and libgcc_s.
- `termoak` links libxcb, libxkbcommon and libxkbcommon-x11, and loads at run
  time (dlopen) the Vulkan loader, libwayland-client and, for the GL
  fallback, libEGL/libwayland-egl. Fonts come from the fontconfig files read
  by a built-in parser, so there is no libfontconfig dependency, only fonts.
  It does not use ALSA.

Per format:

- deb: `libc6 (>= <newest GLIBC_x.y used>)`, `libgcc-s1`, and for the desktop
  `libxcb1 libxkbcommon0 libxkbcommon-x11-0 libvulkan1 libwayland-client0`;
  Recommends `mesa-vulkan-drivers | vulkan-icd`, `libegl1`, `libwayland-egl1`
  and fonts.
- rpm: by soname, as rpm's own elfdeps would generate them
  (`libm.so.6(GLIBC_2.35)(64bit)`, `libxkbcommon-x11.so.0()(64bit)`...), so
  one package resolves on Fedora/RHEL and openSUSE alike. Plain
  `libc.so.6(GLIBC_x)` is not enough: RHEL 9 backports `GLIBC_2.35` in libc
  but not in libm, which the desktop needs. The dlopen()ed libraries are
  added by soname; Vulkan drivers and fonts are weak dependencies
  (Recommends) with the Fedora and openSUSE names.
- pacman: `glibc>=x.y`, `gcc-libs` and, for the desktop, `libxcb libxkbcommon
  libxkbcommon-x11 vulkan-icd-loader wayland`. nfpm cannot write
  `optdepends`, so the Vulkan driver and font hints are on the index page.

Resulting minimum: glibc 2.34 for the CLI and server (Debian 12, Ubuntu
22.04, RHEL/Alma/Rocky 9, Fedora, openSUSE Tumbleweed and Leap 16, Arch) and
glibc 2.35 for the desktop (not RHEL 9 or Leap 15, which are refused by the
package manager).

**Desktop.** The binary goes to `/usr/bin/termoak-desktop`, the desktop entry
to `/usr/share/applications/com.termoak.Termoak.desktop` (it matches the app
id, `StartupWMClass=com.termoak.Termoak`) and the icon, rendered from the
release's `assets/icon.svg`, to `hicolor` (16 to 512 px plus scalable). The
app's self-updater treats `/usr/` installs as managed by the system and only
tells the user about new versions.

**Server.**

- `/usr/bin/termoak-server`.
- `/etc/termoak/config.toml`: the release's `config.example.toml` with
  `data_dir = "/var/lib/termoak"` and the session holder enabled
  (`holder_socket = "/run/termoak-sessions/sessions.sock"`). It is a
  configuration file kept on upgrades (deb conffile, rpm
  `%config(noreplace)`, pacman `backup`), owned `root:termoak`, mode 0640.
  The original example is in `/usr/share/doc/termoak-server/`.
- `termoak-server.service` (from the release tarball) and
  `termoak-sessions.service` (from `deploy/` at the same tag) in
  `/usr/lib/systemd/system/`, with the binary path changed to `/usr/bin`.
- `/usr/lib/sysusers.d/termoak.conf` and `/usr/lib/tmpfiles.d/termoak.conf`.
  The pre-install script creates the `termoak` system user with
  `systemd-sysusers` or, without systemd, `useradd`; the post-install script
  creates `/var/lib/termoak` (0700) and sets the config group.
- Nothing is enabled or started; a fresh install prints a short note with
  the next steps. On upgrade, `termoak-server` is restarted only if it was
  running (`try-restart`); the session holder is left alone so sessions
  survive. On removal both services are stopped and disabled; the user and
  `/var/lib/termoak` are kept.

The maintainer scripts are shared by the three formats and tell the cases
apart by their arguments (`configure`/`remove`/`upgrade` for dpkg, `1`/`2`/`0`
for rpm, versions for pacman).

## Testing

```sh
scripts/test-repo.sh                  # all distros
scripts/test-repo.sh fedora:latest    # one
scripts/test-repo.sh --rmi            # remove the distro images afterwards
```

It copies the staging repository to a temporary directory, builds a second
copy with `termoak-cli` and `termoak-server` as package release 2 (for the
upgrade path), serves both on `127.0.0.1` with `python3 -m http.server` and
runs `tests/<family>.sh` in containers with `--network host`. Nothing is
deployed. Each test follows the index page instructions and checks:

- that the repository is rejected without the key (apt, pacman), that the key
  is imported and package signatures verify (`gpgcheck=1`,
  `repo_gpgcheck=1`, `rpm -K`), never with `--allow-unauthenticated` or
  `--gpg-auto-import-keys`;
- `termoak --version`, `termoak-server --version`, the `termoak` user,
  permissions of `/var/lib/termoak` and the config, `systemd-analyze verify`
  of the units (when systemd is installed);
- the desktop: installing 0.2.1 and upgrading to the latest, `ldd` with no
  missing libraries, and the dlopen()ed libraries present (it cannot start
  without a display);
- upgrading CLI and server to release 2 keeps a local change in
  `config.toml`; removal (and purge on Debian).

| Image                 | Format | Notes                                                          |
|-----------------------|--------|----------------------------------------------------------------|
| `debian:12`           | apt    | with Recommends (systemd, `systemd-sysusers` path)             |
| `ubuntu:22.04`        | apt    | oldest glibc supported by the desktop (2.35)                   |
| `ubuntu:24.04`        | apt    | `--no-install-recommends` (no systemd, `useradd` path)         |
| `fedora:latest`       | dnf5   | `dnf config-manager addrepo --from-repofile`                    |
| `almalinux:9`         | dnf4   | CLI and server; the desktop must be refused (`libm GLIBC_2.35`) |
| `opensuse/tumbleweed` | zypper | `rpm --import` + `zypper addrepo --refresh <.repo>`             |
| `opensuse/leap:16.0`  | zypper | same                                                           |
| `archlinux:latest`    | pacman | `SigLevel = Required DatabaseRequired`, downgrade with `-U`     |

Logs go to `out/test-logs/`. The arm64/aarch64 packages are built and
indexed but not installed by the tests (no emulation on the build host).

## Not covered yet

- **Alpine (apk)**: the binaries are glibc builds; Alpine needs musl builds
  of the CLI and server first.
- **AUR** (`termoak-bin`, `termoak-cli-bin`, `termoak-server-bin`): needs the
  AUR account.
- arm64 desktop builds.
- Publishing the key to a keyserver (the instructions download it from
  pkg.termoak.com instead).
- The Flathub submission ([steps](docs/flathub/README.md)) and an aarch64
  Flatpak.
- F-Droid screenshots (`fdroid/metadata/com.termoak/*/images/phoneScreenshots/`)
  and the inclusion in f-droid.org ([draft](docs/fdroid/README.md)).

## License

[AGPL-3.0](LICENSE). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
"Termoak" and the logo are trademarks of Ohz Digital SL: see
[TRADEMARK.md](TRADEMARK.md).
