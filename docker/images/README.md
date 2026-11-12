# Helper images

Two small images the Kubernetes chart runs instead of a bare `alpine`, so that
its pods install and download nothing when they start.

| Image | Used by (chart values) | Contents |
| --- | --- | --- |
| `ghcr.io/<owner>/openldap-init` | `initImage` | Alpine + `openldap openldap-clients openldap-back-mdb openldap-overlay-all curl jq` (the `ldap` account is created at build time) |
| `ghcr.io/<owner>/openldap-tools` | `cli.image`, `tls.job.image` | Alpine + `curl ca-certificates jq openssl`, `openldap-cli`, and kubectl for three minors |

Without them the chart scripts `apk add` packages and download `openldap-cli`
and `kubectl` on every pod start. That still works with `repository: alpine`,
but it needs outbound access, slows every boot and Job, and a runtime sensor
(Tetragon, Falco) rightly reports binaries written then executed inside a
running container as drift.

## kubectl and the version skew policy

kubectl only supports API servers one minor version away from it. The tools
image ships the newest stable minor **M**, plus **M-2** and **M-4**: each covers
its own minor +/- 1, so together they serve **M-5 to M+1**, seven contiguous
minors.

`/usr/local/bin/kubectl` is a launcher (`openldap-tools/kubectl-select.sh`). On
first use it reads the API server version (`GET /version` with the pod's
service account), runs the bundled release closest to it, and caches the
choice for the life of the container. It warns on stderr when the server is
outside the covered range, and `KUBECTL_MINOR=<n>` forces a release.

## Build and release

`.github/workflows/tool-images.yml` runs every Monday (and on demand, or on a
change under `docker/images/`):

1. resolves the latest patch of the three kubectl minors (`dl.k8s.io`), the
   latest `openldap-cli` release and the current `alpine` digest;
2. rebuilds both images only when one of them changed (a fingerprint label on
   the published image records what it was built from), verifying every
   downloaded binary against its published checksum and smoke-testing the
   result;
3. pushes them under an immutable tag (`YYYY.MM.DD-<run>`) and `latest`;
4. opens a pull request pointing the chart values at the new tag
   (`.github/scripts/bump-tool-images.py`). Merging it releases the chart, so
   the chart never references an image that is not published.

Local build:

```bash
docker build -t openldap-init docker/images/openldap-init
docker build -t openldap-tools \
  --build-arg KUBECTL_VERSIONS="v1.37.2 v1.35.10 v1.33.13" \
  --build-arg CLI_VERSION="v2026.11.1" \
  docker/images/openldap-tools
```
