# OpenLDAP platform

Production-oriented **OpenLDAP** deployment recipes, packaged per target
platform. Same directory tree, same overlays, same companion CLI - pick the
runtime that matches your infrastructure.

## Layouts

| Target | Path | Modes |
|--------|------|-------|
| **Docker Compose** | [`docker/`](docker/) | standalone · HA active-passive (MirrorMode) · HA active-active (N-way multi-master) |
| **Kubernetes (Helm chart)** | [`kubernetes/`](kubernetes/) | standalone · mirror · multi-master (+ full-auto HPA scaling) · +cross-cluster mesh · +read-only replica pool |

Both layouts share the same LDIF bootstrap, the same overlays (memberof,
refint, ppolicy, dynlist, accesslog, syncprov) and the same
[openldap-cli](https://github.com/maximewewer/openldap-cli) admin surface.

## Feature parity

Behaviours common to both platforms:

- OpenLDAP on the minimal [cleanstart/openldap](https://hub.docker.com/r/cleanstart/openldap) image
- Delta-syncrepl HA (accesslog + syncprov)
- Least-privilege ACLs per OU, SSHA-hashed passwords, TLS/LDAPS
- Idempotent bootstrap + cert renewal (Docker: cron; Kubernetes: CronJob)
- Full admin surface via `openldap-cli` (users, groups, ppolicy, ACLs, overlays, tree-grants, backup, diagnostics)
- Prometheus monitoring via [openldap_prometheus_exporter](https://github.com/maximewewer/openldap_prometheus_exporter)
- POSIX schema toggle for SSH / UNIX login
- Backup + accesslog purge automation

Kubernetes-only additions:

- Six declarative blocks reconciled on every `helm upgrade` - users, groups, policies, ACLs, tree-grants, overlays - one post-install/upgrade sync Job each
- Full-auto horizontal scaling in `multi-master`: HPA v2 (CPU/mem/Prometheus-adapter metrics) + chart-native cron scale windows (`scaleSchedule`), with an in-cluster scale-watcher Deployment that rebuilds `cn=config` peer topology on every scale event - no manual `kubectl rollout restart`
- Periodic `config acl lint` CronJob to flag shadowed / no-op olcAccess rules
- Per-user password Secret backend (nothing sensitive in `values.yaml`)
- Three TLS backends: `cert-manager`, in-cluster `job` (self-signed + auto-renew + rolling restart), or user-`provided`
- Ingress via `ingress-nginx` SSL passthrough or Gateway API `TLSRoute`
- Read-only replica pool for read-heavy fan-out
- NetworkPolicy + auto-PDB + PSA-restricted-ready hardening
- GitOps-ready reference manifests (Argo CD + Flux) + cross-cluster HA runbook

## Companion tooling

- **[openldap-cli](https://github.com/maximewewer/openldap-cli)** - single static Go binary. Day-to-day admin (users, groups, ppolicy, backup, diagnostics). Called by Docker admins directly and by the Kubernetes chart's sync Jobs.
- **[openldap_prometheus_exporter](https://github.com/maximewewer/openldap_prometheus_exporter)** - Prometheus scraper for `cn=Monitor`. Docker: opt-in `metrics` compose profile (`ENABLE_EXPORTER=true`); Kubernetes: sidecar in the StatefulSet + `ServiceMonitor` + baseline `PrometheusRule`.

## Quick start

### Docker Compose

```bash
cd docker/standalone
bash certs.sh          # optional: generate TLS material
bash setup.sh          # bootstrap + start
```

HA modes ship a 3-VM Vagrant test cluster (`docker/ha-active-*/tests/`).
Full docs: [`docker/README.md`](docker/README.md).

### Kubernetes

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  --namespace ldap --create-namespace
```

Retrieve the auto-generated admin credentials:

```bash
kubectl -n ldap get secret ldap-openldap-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

Full docs: [`kubernetes/README.md`](kubernetes/README.md).
Operator handbook: [`kubernetes/docs/`](kubernetes/docs/) (recipes,
troubleshooting, sizing, backup/DR, migrate-from-docker, scaling, ...).
GitOps + cross-cluster HA: [`kubernetes/gitops/`](kubernetes/gitops/) and
[`kubernetes/docs/cross-cluster.md`](kubernetes/docs/cross-cluster.md).

## Repository layout

```
openldap-platform/
├── docker/                         # Docker Compose recipes (standalone + 2 HA modes)
│   ├── README.md                   # comprehensive per-mode ops handbook
│   ├── base-ldifs/                 # shared bootstrap LDIFs (OUs, admin, policies)
│   ├── standalone/                 # 1 slapd container
│   ├── ha-active-passive/          # 2 masters (MirrorMode) + consumers + HAProxy
│   └── ha-active-active/           # N masters (multi-master) + HAProxy
└── kubernetes/                     # Helm chart + operator handbook + test rig
    ├── README.md                   # feature-complete chart overview
    ├── Makefile                    # docs / docs-check / lint / dep-update
    ├── charts/openldap-platform/   # umbrella (openldap + phpldapadmin + SSP)
    ├── docs/                       # operator handbook (recipes, troubleshooting, cross-cluster, scaling, …)
    ├── gitops/                     # Argo CD + Flux reference manifests
    └── tests/cross-cluster/        # 2-VM Vagrant + minikube rig for cross-cluster HA
```

## License

See [LICENSE](LICENSE).
