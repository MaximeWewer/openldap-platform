# Tooling image for the chart's Jobs, CronJobs and scale watcher (cli.image,
# tls.job.image).
#
# Their scripts download openldap-cli and kubectl, and `apk add` curl, jq and
# openssl, whenever the command is missing. Baking them in removes every
# download at run time: no dependency on GitHub, dl.k8s.io or the Alpine CDN,
# and no binary written then executed inside a running container.
#
# kubectl only supports API servers one minor version away (version skew
# policy). The image therefore carries several releases two minors apart -
# each covers its own minor +/- 1, so three of them span seven contiguous
# minors - and /usr/local/bin/kubectl is a launcher that picks the one closest
# to the API server it talks to.
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION}

# Space-separated full versions, newest first, e.g. "v1.37.2 v1.35.6 v1.33.9".
ARG KUBECTL_VERSIONS
# openldap-cli release tag, e.g. "v2026.10.2".
ARG CLI_VERSION
ARG CLI_DOWNLOAD_URL=https://github.com/maximewewer/openldap-cli/releases/download

RUN apk add --no-cache curl ca-certificates jq openssl

# Every binary is checked against the checksum its project publishes beside
# it; a mismatch fails the build instead of shipping the binary.
RUN set -eu; \
    : "${KUBECTL_VERSIONS:?}"; mkdir -p /usr/local/lib/kubectl; \
    for v in ${KUBECTL_VERSIONS}; do \
      base="https://dl.k8s.io/release/${v}/bin/linux/amd64/kubectl"; \
      curl --retry 3 --retry-delay 3 -fsSL "${base}" -o /tmp/kubectl; \
      echo "$(curl --retry 3 -fsSL "${base}.sha256")  /tmp/kubectl" | sha256sum -c -; \
      minor=$(echo "${v}" | sed -E 's/^v1\.([0-9]+)\..*/\1/'); \
      install -m 0755 /tmp/kubectl "/usr/local/lib/kubectl/kubectl-1.${minor}"; \
      rm -f /tmp/kubectl; \
    done

RUN set -eu; \
    : "${CLI_VERSION:?}"; \
    tarball="openldap-cli_${CLI_VERSION}_linux_amd64.tar.gz"; \
    curl --retry 3 --retry-delay 3 -fsSL "${CLI_DOWNLOAD_URL}/${CLI_VERSION}/${tarball}" -o /tmp/cli.tgz; \
    curl --retry 3 --retry-delay 3 -fsSL "${CLI_DOWNLOAD_URL}/${CLI_VERSION}/checksums.txt" -o /tmp/cli.sums; \
    want=$(awk -v f="${tarball}" '$2 == f || $2 == "*" f { print $1; exit }' /tmp/cli.sums); \
    [ -n "${want}" ]; \
    echo "${want}  /tmp/cli.tgz" | sha256sum -c -; \
    tar -xzf /tmp/cli.tgz -C /usr/local/bin openldap-cli; \
    chmod 0755 /usr/local/bin/openldap-cli; \
    rm -f /tmp/cli.tgz /tmp/cli.sums

COPY kubectl-select.sh /usr/local/bin/kubectl

LABEL org.opencontainers.image.title="openldap-tools" \
      org.opencontainers.image.description="openldap-cli, kubectl (several minors) and the tools used by the openldap-platform Jobs" \
      org.opencontainers.image.source="https://github.com/maximewewer/openldap-platform" \
      io.openldap-platform.cli-version="${CLI_VERSION}" \
      io.openldap-platform.kubectl-versions="${KUBECTL_VERSIONS}"
