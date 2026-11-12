# Bootstrap image for the slapd initContainers (initImage in the chart).
#
# The bootstrap script installs these packages with `apk add` when slappasswd
# is missing. Shipping them in the image means no package manager runs at pod
# start: faster, reproducible boots, no outbound access to the Alpine CDN, and
# nothing for a runtime sensor (Tetragon, Falco) to report as container drift.
# The `ldap` account is created here, by the openldap package, at build time.
ARG ALPINE_VERSION=3.24
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
      openldap openldap-clients openldap-back-mdb openldap-overlay-all \
      curl jq

LABEL org.opencontainers.image.title="openldap-init" \
      org.opencontainers.image.description="Alpine with the slapd tools used by the openldap-platform bootstrap" \
      org.opencontainers.image.source="https://github.com/maximewewer/openldap-platform"
