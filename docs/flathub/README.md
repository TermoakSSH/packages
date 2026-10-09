# Termoak on Flathub (prepared, not submitted)

Termoak already has its own Flatpak repository,
`https://pkg.termoak.com/flatpak/termoak.flatpakrepo` (see the
[main README](../../README.md#linux-flatpak)). This page prepares the
submission of the same app, `com.termoak.Termoak`, to
[Flathub](https://flathub.org), which builds every app from source on its own
infrastructure. Nothing has been submitted yet.

The submission is the `flatpak/` directory of
[TermoakSSH/desktop](https://github.com/TermoakSSH/desktop/tree/main/flatpak):

| File | Goes to the Flathub repository as |
|------|-----------------------------------|
| `com.termoak.Termoak.yml` | the manifest (same name) |
| `cargo-sources.json` | same name, next to it |
| `patches/desktop-v0.6.0-flatpak.patch` | same path (only while the manifest builds 0.6.0) |

The desktop entry, the AppStream metadata (`com.termoak.Termoak.metainfo.xml`)
and the icons are upstream, in `assets/linux/` of the desktop repository, and
the manifest installs them from the source; for 0.6.0 they come with the
patch.

## Status

- Builds from source with flatpak-builder 1.4.4 on
  `org.freedesktop.Platform//26.08` + `rust-stable`, offline, from the
  `desktop-v0.6.0` tag (commit `cbb1132`) and `cargo-sources.json`.
- `appstreamcli validate --strict`: passes (one pedantic note: the id has
  uppercase letters, which Flathub expects for `com.termoak.Termoak`).
- `desktop-file-validate`: passes (one hint: two main categories, Network and
  System, on purpose).
- Installed and run from the pkg.termoak.com repository in a clean container:
  `--version` and the window under Xvfb.
- Flathub's linter: see [Linter](#linter).

## Linter

```sh
flatpak install flathub org.flatpak.Builder
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest com.termoak.Termoak.yml
flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo   # the built repo
```

`scripts/flatpak.sh --lint` runs both in the build container.

Results (org.flatpak.Builder from Flathub, 2026-10-09):

| Check | Manifest | Built repo | What to do |
|-------|----------|------------|------------|
| `finish-args-flatpak-spawn-access` | error | error | Exception: host shell of the local terminal (see below) |
| `finish-args-has-socket-ssh-auth` | error | error | Exception: SSH client using the user's agent |
| `finish-args-ssh-filesystem-access` | error | error | Exception: `~/.ssh:ro` for the ssh config import; if refused, drop that line (the import then works only through the file chooser, without the `IdentityFile` keys) |
| `appstream-external-screenshot-url` | | error | Expected outside Flathub: Flathub's build mirrors the screenshots to `dl.flathub.org/media` |
| `appstream-screenshots-not-mirrored-in-ostree` | | error | Same: only Flathub's infrastructure mirrors them |

Nothing else is reported: the AppStream metadata, the desktop file, the
icons, the app id, the runtime and the build options pass. The three
permission errors are deliberate and need exceptions, which Flathub grants
per app (in `flathub-infra/flatpak-builder-lint`'s exceptions list) when the
reviewers accept the reasons given in the PR.

## Steps to submit

1. **Account**: a GitHub account that will maintain the app (Oihalitz or a
   TermoakSSH org account); Flathub uses GitHub to log in.
2. **Fork** https://github.com/flathub/flathub with *Copy the `master` branch
   only* **unchecked** (submissions go to the `new-pr` branch).
3. Clone the `new-pr` branch and add the files:
   ```sh
   git clone --branch=new-pr git@github.com:<you>/flathub.git
   cd flathub
   git checkout -b com.termoak.Termoak
   cp -r /root/Termoak/desktop/flatpak/{com.termoak.Termoak.yml,cargo-sources.json,patches} .
   git add . && git commit -m "Add com.termoak.Termoak"
   git push -u origin com.termoak.Termoak
   ```
   Optionally a `flathub.json` with `{"only-arches": ["x86_64"]}` if the
   aarch64 build is not wanted (Flathub builds x86_64 and aarch64 by
   default; the app has only been built for x86_64 so far).
4. **Pull request** against `flathub/flathub`, base branch **`new-pr`**,
   title `Add com.termoak.Termoak`, filling in the checklist of the PR
   template. Explain the permissions there (below). Comment
   `bot, build` to start a test build; the bot posts the result and a
   `flatpak install` command for the test build.
5. **Review**: answer the reviewers; when it is merged, Flathub creates
   `flathub/com.termoak.Termoak`, and the maintainer gets write access to it.
   From then on, new versions are PRs to that repository (the
   `x-checker-data` of the git source makes Flathub's bot open them when a
   `desktop-vX.Y.Z` tag appears; `cargo-sources.json` has to be regenerated
   with `flatpak/update-sources.sh` in the same PR).
6. **Verification** (the "verified" badge, under the developer
   *Ohz Digital SL*): log in to https://flathub.org/developer-portal, open
   the app and choose verification by website: put the token it shows in
   `https://termoak.com/.well-known/org.flathub.VerifiedApps.txt`
   (served by the Termoak server's web directory).

## Permissions to justify in the PR

- `--talk-name=org.freedesktop.Flatpak`: the app has a local terminal; it
  runs the user's login shell on the host with `flatpak-spawn --host`, as
  other terminal emulators on Flathub do (Ptyxis, Black Box, Prompt). This is
  a sandbox escape, so the linter reports it and it needs an exception.
- `--socket=ssh-auth`: SSH client; authenticates with the keys of the user's
  agent.
- `--talk-name=org.freedesktop.secrets`: the key of the local encrypted vault
  is kept in the Secret Service (the `keyring` crate over D-Bus; libsecret's
  portal backend is not used).
- `--talk-name=org.freedesktop.Notifications`: notifications while the
  window is in the background (GPUI posts them with notify-rust).
- `--filesystem=~/.ssh:ro`: "Import ~/.ssh/config" reads the config and the
  `IdentityFile` keys it points to; read-only.
- `--filesystem=xdg-download`: SFTP downloads. Everything else goes through
  the file chooser portal; no `--filesystem=home`.
- `--share=network`, `--socket=wayland`, `--socket=fallback-x11`,
  `--share=ipc`, `--device=dri`: an SSH client with a GPU-rendered (Vulkan)
  window.

## Notes for the reviewers' usual questions

- **Source build**: everything from source; `cargo-sources.json` comes from
  flatpak-builder-tools' `flatpak-cargo-generator` (pinned commit in
  `docker/flatpak.Dockerfile` here). The only git dependency is
  TermoakSSH/core at tag `v0.6.0`.
- **Updates**: the app's self-updater is not compiled in (no
  `TERMOAK_UPDATE_PUBKEY`) and turns itself off in a Flatpak
  (`src/flatpak.rs`, `src/update.rs`).
- **License**: AGPL-3.0-only (`project_license`), metadata CC0-1.0.
- **Screenshots**: PNGs in the desktop repository at the release tag
  (`docs/*.png`, 1440×900), mirrored by Flathub on build.
- **Patch**: the 0.6.0 release predates the Flatpak support; the patch is
  the commit on `main` that adds it and goes away with the next release.
