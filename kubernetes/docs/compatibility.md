# Compatibility matrix

Versions the chart is developed and validated against. Anything below
the "Minimum" column has NOT been tested - file an issue if you find it
works (or doesn't).

## Kubernetes

| Component | Minimum | Tested | Notes |
|-----------|---------|--------|-------|
| Kubernetes API | 1.27 | 1.29 | `kubeVersion` in Chart.yaml enforces the floor. Gateway API TLSRoute requires 1.25+, and the chart uses `apiVersion` `v1` (stable) / `v1alpha2` (TLSRoute). |
| Helm CLI | 3.13 | 3.15, 4.2 | The chart uses `lookup`, `fromJsonArray`, `toJson` - Helm 3.13+ ships them. |
| CoreDNS | any | 1.11 | Only needed for the in-cluster peer DNS names. |

## Container runtimes

| Runtime | Notes |
|---------|-------|
| containerd | Default target. |
| CRI-O | Should work - no image-format specifics. |
| docker-shim (retired < 1.24) | Untested; upgrade the cluster. |

## CNI (for NetworkPolicy enforcement)

| CNI | NetworkPolicy? | Notes |
|-----|----------------|-------|
| Calico | ✅ | Enforces the chart's default-deny out of the box. |
| Cilium | ✅ | Also supports the chart's Gateway API TLSRoute. |
| kube-router | ✅ | Enforces NP; no Gateway API. |
| Antrea | ✅ | |
| Weave Net | ✅ | |
| minikube `bridge` (default) | ❌ | Chart resources render but nothing filters. Use `minikube start --cni=calico` for real testing. |
| kindnet (default in kind) | ❌ | Same story. |

## Optional dependencies

The chart auto-detects - nothing forces you to install them unless the
matching feature is enabled.

| Dependency | Enabled by | Version tested |
|------------|-----------|----------------|
| **cert-manager** | `openldap.tls.backend: cert-manager` and/or subchart Ingress cert-manager | v1.14, v1.15 |
| **prometheus-operator** (or kube-prometheus-stack) | `openldap.monitoring.serviceMonitor.enabled` / `openldap.monitoring.prometheusRule.enabled` | 0.72 (CRDs) - the chart uses the `monitoring.coreos.com/v1` API |
| **ingress-nginx** | `ingress.mode: ingress-nginx` | 1.10 - controller MUST run with `--enable-ssl-passthrough` for LDAPS |
| **Gateway API** | `ingress.mode: gateway-api` | v1 for HTTPRoute / Gateway, v1alpha2 for TLSRoute. Confirmed on Cilium 1.15 and Istio 1.22. |
| **external-secrets** | `openldap.secrets.backend: external-secrets` + any `existingSecret` value | 0.9 (both `v1` and `v1beta1`) |

## OpenLDAP image

- **Runtime**: `ghcr.io/maximewewer/openldap:2.7.1` (distroless, ~74 MB). Ships
  slapd + back_mdb + overlays; no shell.
- **Init**: `alpine:3.24` (~7 MB). Installs `openldap`,
  `openldap-back-mdb`, `openldap-overlay-all`, `openldap-clients` at
  runtime - the OpenLDAP version pulled from Alpine is 2.6.6, which is
  The image also supplies the `slapadd` that seeds the database, in two
  init containers between the renderer and the finalizer - the on-disk
  format is tied to the OpenLDAP major, so the loader must be the server.

Test upgrading to a newer 2.6.x tag by overriding `openldap.image.tag`.
The chart's bootstrap contract only depends on:
- `slapd -F <dir>` accepting the same cn=config layout.
- Modules named `back_mdb.so`, `memberof.so`, `refint.so`, `ppolicy.so`,
  `dynlist.so`, `accesslog.so`, `syncprov.so` under `/usr/lib/openldap`.

Both hold across every 2.6 release.

## Companion binaries (downloaded at Job runtime)

| Binary | Default version | Where |
|--------|-----------------|-------|
| `openldap-cli` | v2026.10.1 | `openldap.cli.version` - pinned per release for reproducibility. |
| `kubectl` | v1.36.2 | `openldap.cli.kubectlVersion` - used by sync/backup/tls Jobs for Secret CRUD + STS rollout. |

Both downloads are checksum-verified before use: against the `checksums.txt` /
`kubectl.sha256` each project publishes, or against `openldap.cli.sha256` /
`openldap.cli.kubectlSha256` when you pin the digests yourself.

`openldap.cli.passwordFiles` (default `true`) passes the admin and config-admin
passwords to the CLI as file paths (`LDAP_BIND_PW_FILE`,
`LDAP_CONFIG_BIND_PW_FILE`) and creates users with `--password-stdin`, so no
password reaches a Job's environment or command line. Those three landed in
**openldap-cli v2026.9.1**: if you pin `openldap.cli.version` to anything older,
set `passwordFiles: false` as well, or the older binary ignores the `*_FILE`
variables and binds with an empty password.

`openldap.tlsCheckCronJob` calls `tls check`, which landed in **v2026.10.1**.
Pinning the CLI below that and enabling the CronJob fails the Job on an unknown
subcommand. `onOuChange: move` needs **v2026.7.4** (`user move`,
`entry rename --newsuperior`), and the declarative `acls` / `treeGrants` /
`overlays` blocks need **v2026.7.4** as well.

## OpenLDAP major versions

`cleanstart/openldap` no longer publishes any 2.6 tag; 2.7.0 and 2.7.1 are
what is left. 2.7 changed back-mdb's on-disk format, so a data directory
written by 2.6 makes slapd 2.7 exit with `MDB_INVALID` - the move is a dump
and reload, automated by `openldap.majorUpgrade.enabled` or driven by hand
with `scripts/openldap-migrate.sh`. See
[`migrate-2.6-to-2.7.md`](migrate-2.6-to-2.7.md).

Two other 2.7 changes to know about:

- `olcRefintAttribute` with several names in one value was a deprecation
  warning in 2.6 and is a hard error in 2.7. The chart and the Compose stacks
  already write one name per value.
- The `cleanstart/openldap` runtime and `-dev` images disagree on the `ldap`
  uid/gid (102:103 vs 101:102). The chart is unaffected - it runs `slapd`
  under `securityContext.runAsUser` with its own `/run/openldap` - but the
  Compose stacks read the uid out of the image for exactly this reason.

## Prometheus exporter

- Image: `ghcr.io/maximewewer/openldap_prometheus_exporter:2026.9.1`
  (pin a tag in prod). Exposes port 9330.
- Binds as `cn=adminconfig,cn=config`.

## Storage

- `ReadWriteOnce` volumes on any CSI. StatefulSet uses one PVC per
  replica; no shared-storage requirement.
- Expansion: bumping `persistence.size` requires a StorageClass with
  `allowVolumeExpansion: true` **and** `kubectl edit pvc` on each PVC -
  StatefulSet won't recreate them.

## Local development / test clusters

Tested:
- **minikube** 1.38 with the `docker` driver (CPU 2, memory 4 GiB).
  NetworkPolicy not enforced.
- **kind** 0.23. Same NP caveat.

## Not tested (patches welcome)

- OpenShift Routes (chart uses standard Ingress / Gateway API).
- Rancher / RKE-specific storage.
- ARM64 nodes (both cleanstart and alpine images support arm64, but
  none of the CI runs exercised it).
- OpenLDAP 2.5 / 2.4 - the chart depends on delta-syncrepl behaviour
  that stabilised in 2.6.
