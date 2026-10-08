# Tool image for scripts/fdroid.sh: fdroidserver (fdroid update/verify,
# signing of the index), apksigner, the JDK's keytool/jarsigner and qrencode
# (QR code of the repository for the index page), from Debian 13 (trixie).
# Built locally on demand:
#   docker build -t termoak-fdroid -f docker/fdroid.Dockerfile docker/
# The base image is pinned by digest and the main tools by Debian version;
# when Debian replaces one of these versions in a point release the build
# fails, and the ARG has to be raised.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

ARG FDROIDSERVER_VERSION=2.4.2-1
ARG APKSIGNER_VERSION=35.0.2-1
ARG QRENCODE_VERSION=4.1.1-2

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "fdroidserver=${FDROIDSERVER_VERSION}" \
      "apksigner=${APKSIGNER_VERSION}" \
      "qrencode=${QRENCODE_VERSION}" \
      ca-certificates openssl unzip \
 && rm -rf /var/lib/apt/lists/* \
 && fdroid --version && apksigner --version && qrencode --version 2>&1 | head -n1

# A writable HOME for fdroid's and the JDK's per-user files.
ENV HOME=/tmp/home
RUN install -d -m 700 /tmp/home
