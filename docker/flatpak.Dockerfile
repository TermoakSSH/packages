# Tool image for scripts/flatpak.sh: flatpak and flatpak-builder (build the
# app from source, export it to the signed OSTree repository), appstream
# (appstreamcli validate and compose, with the SVG loader of gdk-pixbuf for
# the icon), desktop-file-utils, the Python modules of
# flatpak-cargo-generator (cargo-sources.json), Xvfb and D-Bus for the smoke
# test, from Debian 13 (trixie). Built locally on demand:
#   docker build -t termoak-flatpak -f docker/flatpak.Dockerfile docker/
#
# The runtimes, the SDK extensions and org.flatpak.Builder (Flathub's linter)
# are not in the image: they go to a persistent installation that
# scripts/flatpak.sh mounts at /var/lib/flatpak (out/flatpak-cache/system).
#
# flatpak-builder sandboxes every build step with bubblewrap, so the
# container runs with --cap-add SYS_ADMIN --cap-add NET_ADMIN and
# --security-opt seccomp=unconfined, apparmor=unconfined and
# systempaths=unconfined (namespaces and mounting /proc; no --privileged)
# and builds with --disable-rofiles-fuse (no /dev/fuse).
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      flatpak flatpak-builder appstream desktop-file-utils librsvg2-common \
      ostree gnupg git ca-certificates curl patch xz-utils zstd \
      python3 python3-aiohttp python3-tomlkit python3-yaml \
      xvfb xauth dbus dbus-x11 \
 && rm -rf /var/lib/apt/lists/* \
 && flatpak --version && flatpak-builder --version && appstreamcli --version

# flatpak-cargo-generator (cargo-sources.json from Cargo.lock), pinned.
ARG FBT_COMMIT=41c20aa10819cdb2a4f3ca171758a96d1955c018
RUN curl -fsSL -o /usr/local/bin/flatpak-cargo-generator \
      "https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/${FBT_COMMIT}/cargo/flatpak-cargo-generator.py" \
 && chmod 755 /usr/local/bin/flatpak-cargo-generator \
 && python3 /usr/local/bin/flatpak-cargo-generator --help >/dev/null

# gpg-agent needs a writable socket directory: GNUPGHOME is mounted read-only.
RUN install -d -m 700 /run/user/0
ENV HOME=/root
