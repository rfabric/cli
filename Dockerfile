# ghcr.io/rfabric/cli:<version>: the pinned rfabric CLI and the CI wrapper scripts; the
# Bitbucket pipe (ENTRYPOINT) and the GitLab template's job image (entrypoint: [""]).
#
#   docker buildx build --platform linux/amd64,linux/arm64 --build-arg RFABRIC_VERSION=<version> .
#
# RFABRIC_VERSION defaults to VERSION. RFABRIC_CLI=local (tests only) copies the binary
# `rfabric` from the build context `cli` (--build-context cli=<dir>) instead of installing
# the release.
ARG RFABRIC_CLI=release

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS base
# safe.directory: the clone directory belongs to another user than the job; git reads HEAD there.
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git jq \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*'

FROM base AS cli-release
ARG RFABRIC_VERSION
COPY VERSION /tmp/VERSION
# The installer is downloaded first, so a failed download fails the build, and the build checks
# that the installed CLI is the pinned version.
RUN version="${RFABRIC_VERSION:-$(cat /tmp/VERSION)}" \
    && version="${version#v}" \
    && curl -fsSL -o /tmp/cli.sh https://get.rfabric.io/cli.sh \
    && RFABRIC_VERSION="v$version" RFABRIC_INSTALL_DIR=/usr/local/bin sh /tmp/cli.sh \
    && rfabric version --output json | jq -e --arg version "$version" '.version == $version' > /dev/null \
    && rm /tmp/VERSION /tmp/cli.sh

FROM base AS cli-local
COPY --from=cli rfabric /usr/local/bin/rfabric

FROM cli-${RFABRIC_CLI}
COPY scripts/sim-run.sh scripts/gitlab.sh scripts/pipe.sh /opt/rfabric/scripts/
ENTRYPOINT ["/opt/rfabric/scripts/pipe.sh"]
