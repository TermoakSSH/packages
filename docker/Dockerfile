# Tool image for scripts/publish.sh: nfpm, apt-ftparchive, createrepo_c,
# rpmsign, repo-add (pacman) and gpg in one Fedora container.
# Built locally on demand (`docker build -t termoak-packaging docker/`).
FROM registry.fedoraproject.org/fedora:44

ARG NFPM_VERSION=2.47.0
ARG NFPM_SHA256=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783

RUN dnf -y install --setopt=install_weak_deps=False \
      apt-utils createrepo_c rpm-sign gnupg2 pacman zstd xz gzip \
      librsvg2-tools binutils findutils diffutils \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/libdnf5

RUN curl -fsSL -o /tmp/nfpm.tar.gz \
      "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz" \
    && echo "${NFPM_SHA256}  /tmp/nfpm.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/nfpm.tar.gz -C /usr/local/bin nfpm \
    && rm /tmp/nfpm.tar.gz \
    && nfpm --version

# gpg-agent needs a writable socket directory: GNUPGHOME is mounted read-only.
RUN install -d -m 700 /run/user/0
