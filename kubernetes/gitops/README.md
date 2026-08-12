# GitOps

The `openldap-platform` chart is deliberately runner-agnostic - it is plain
Helm and holds no controller/operator, so any GitOps engine that can drive
Helm works out of the box. This directory ships reference manifests for
**Argo CD** and **Flux**, plus notes on the couple of details worth calling
out before you plug either one in.

## Chart source

Two ways to point a GitOps runner at the chart:

| Source | Pros | Cons |
|--------|------|------|
| **Git** - this repo at `kubernetes/charts/openldap-platform/` | Follows the same PR/review flow as everything else; per-branch overlays are trivial | Runner must resolve `file://` subchart deps (both Argo & Flux handle this) |
| **OCI registry** - publish the packaged chart to an OCI-compatible registry (`helm push oci://…`) | Immutable, signed, cache-friendly | Extra publish step in CI |

The examples below use the Git path since the chart's subcharts are all
`file://` relative - no extra publish step needed to try it.

## Secrets

The chart auto-generates and preserves several Secrets (admin, replicator,
per-user, keyphrase, APP_KEY). That "preserve" behaviour relies on Helm's
`lookup` function, which needs kubeconfig-level read access to Secrets at
render time. Argo CD and Flux both provide this out of the box; the two
consequences worth remembering:

- **Dry-runs off-cluster** produce fresh random values every time.
- **Never enable Argo CD's "Replace" prune policy** on those Secrets - it
  would wipe them and rotate every credential.

For anything sensitive you'd rather source out-of-band (production admin
passwords, replicator credentials shared across clusters), point the chart
at an existing Secret via the `existingSecret` knobs and let an external
controller populate it. Recommended:

- [external-secrets.io](https://external-secrets.io) with Vault, AWS Secrets
  Manager, GCP Secret Manager, Azure Key Vault, 1Password, …
- [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) if you
  want the encrypted payload to live in Git.

## Helm hooks

The chart ships Helm hooks for:

- **pre-install / pre-upgrade** - `tls-init` Job (when `tls.backend=job`).
  Must complete before slapd starts; blocks the release.
- **post-install / post-upgrade** - `sync-ppolicy` → `sync-users` →
  `sync-groups` Jobs (when the respective lists are non-empty).

Both Argo CD and Flux understand Helm hooks natively - the underlying
`helm install/upgrade` invocation drives them. Nothing extra to configure.
The one thing to know:

- Argo CD reports hook Jobs under `Application → Hooks`, not under
  `Application → Resources` (they aren't part of the release manifest).
- Flux surfaces them in the HelmRelease's `.status.history` after each
  reconciliation.

## Server-side apply gotcha

Both runners default to Server-Side Apply. A couple of chart resources
must be applied as full replacements or SSA fails ownership arbitration:

- Sync Job pods (immutable spec - Argo/Flux will recreate on change).
- The `openldap` StatefulSet's `volumeClaimTemplates` (immutable after
  creation).

Neither is a problem in normal operation - a `helm upgrade` never touches
those fields - but explains why an aggressive `argocd app diff` sometimes
flags "OutOfSync" cosmetically after a hook Job ran.

## Argo CD

See [`argocd/`](./argocd/):
- [`application.yaml`](./argocd/application.yaml) - single Application
  pointing at the chart.
- [`app-of-apps.yaml`](./argocd/app-of-apps.yaml) - the app-of-apps
  pattern for multi-environment (dev/stage/prod).

## Flux

See [`flux/`](./flux/):
- [`gitrepository.yaml`](./flux/gitrepository.yaml) - source of truth.
- [`helmrelease.yaml`](./flux/helmrelease.yaml) - HelmRelease consuming
  the chart from that source.

## Cross-cluster HA

`replication.externalPeers` + `replication.serverIdBase` let you stitch
several openldap-platform releases across clusters into a multi-master mesh.
See [`../docs/cross-cluster.md`](../docs/cross-cluster.md) for the
bootstrap sequence - order matters, and the shared CA has to land on every
cluster before the first peer comes up.
