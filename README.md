# Termoak Linux packages

Packaging and signed repositories for [Termoak](https://termoak.com), served
at **https://pkg.termoak.com**:

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

User-facing install instructions are on the index page of the repository,
generated from [`site/index.html`](site/index.html).

## Layout

```
docker/Dockerfile          tool image (Fedora): nfpm, apt-ftparchive, createrepo_c,
                           rpmsign, repo-add, gpg, rsvg-convert
nfpm/<package>.yaml        nfpm configuration of each package
files/termoak/             desktop entry (com.termoak.Termoak.desktop)
files/termoak-server/      sysusers.d / tmpfiles.d snippets and maintainer scripts
site/index.html            template of the repository index page (en + es)
scripts/publish.sh         downloads releases, builds, signs, regenerates the repos
scripts/build-repo.sh      the part of publish.sh that runs inside the tool image
scripts/test-repo.sh       installs from the staging repo in distro containers
tests/                     the per-distro test scripts used by test-repo.sh
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
```

## Requirements

Only Docker, `curl`, `python3`, `rsync`, `flock` and `gpg` (to check that the
key is there) on the host. Everything else runs in the `termoak-packaging`
image, built from `docker/Dockerfile` the first time (about 470 MB; nfpm is
downloaded with a pinned SHA-256). Nothing is built on GitHub Actions.

The signing key lives in `GNUPGHOME=/root/.config/termoak/repo-gpg` (RSA-4096,
sign-only, fingerprint `BDD6B45E003E53F1B9DE70932C813822C95C7F5B`). It is
mounted **read-only** into the container for signing and never copied; gpg
runs there with `--lock-never` and its agent socket under `/run/user/0`.

## Publishing

```sh
scripts/publish.sh                                   # latest releases -> out/repo
scripts/publish.sh --deploy /var/www/pkg.termoak.com # ... and copy to the web root
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
4. With `--deploy DIR`: rsync of the packages first and then of everything
   else with `--delete-after --delay-updates`, so clients never see metadata
   that points to missing files. **Files in DIR that are not in the staging
   repository are deleted.** If the staging directory is empty and DIR
   already holds a repository, the staging directory is first seeded from it,
   so the older versions in the pool are kept.

Other options: `--only termoak,termoak-cli,termoak-server`, `--no-build`,
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

## License

[AGPL-3.0](LICENSE). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
"Termoak" and the logo are trademarks of Ohz Digital SL: see
[TRADEMARK.md](TRADEMARK.md).
