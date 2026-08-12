# Upgrade & uninstall

## Upgrade

### Standard upgrade

```bash
helm upgrade ldap kubernetes/charts/openldap-platform \
  --namespace ldap \
  -f my-values.yaml
```

- Pod restarts are annotation-driven - the StatefulSet carries a
  `checksum/bootstrap` + `checksum/admin-secret` annotation that changes
  whenever the corresponding ConfigMap / Secret changes.
- The sync Jobs (ppolicy → users → groups) re-run on every upgrade as
  post-install/post-upgrade hooks, reconciling any values.yaml drift.
- Admin passwords, replicator password and per-user passwords are
  preserved across upgrades via Helm's `lookup` + fallback pattern -
  RUNAsIs also caused by `helm.sh/resource-policy: keep` on those
  Secrets.

### What changes trigger a pod restart

| Change | Effect |
|--------|--------|
| `image.tag`, `initImage.tag`, `resources`, probes | Rolling restart |
| `podSecurityContext`, `securityContext`, `networkPolicy.*` | Rolling restart |
| `bootstrap.sh` / `slapd-config.ldif` / `base-data.ldif` (ConfigMap change) | Rolling restart via checksum |
| `admin.existingSecret` change | Rolling restart via checksum (chart-managed Secret) |
| `users` / `groups` / `policies` change | No restart - sync Jobs pick it up |
| `backup.*`, `accesslogPurgeJob.*` | New CronJob spec - next invocation uses it |
| `monitoring.*` | Rolling restart (sidecar spec change) |
| `tls.*` | Rolling restart |
| `replication.externalPeers` | Rolling restart (bootstrap.sh regenerates syncrepl block) |

### What NEVER changes without manual action

- `volumeClaimTemplates` (K8s immutability). Bumping
  `persistence.size` requires:
  1. `kubectl edit pvc data-<release>-openldap-N` on each PVC (if
     StorageClass allows expansion) OR
  2. Backup → destroy PVCs → reinstall → restore.
- `serviceName` on the StatefulSet.

### HA-safe upgrade order

For `mode: multi-master` / `mode: mirror`:

- `updateStrategy.type: RollingUpdate` (chart default) rolls one pod at
  a time, waiting for the new one to be Ready before touching the next.
- Prefer `podManagementPolicy: OrderedReady` (chart default) - every
  peer catches up via syncrepl before the next one goes.
- PodDisruptionBudget `minAvailable: replicas - 1` (chart default)
  blocks concurrent voluntary evictions during node drains.

Combined, a rolling upgrade of a 3-node multi-master takes ~90s wall
clock (30s per pod: terminate → new pod pull image → init container
skip → slapd bind → syncrepl catch-up).

### Cross-cluster upgrades

Roll one cluster at a time; peers on the other clusters keep serving.
Order matters ONLY when `replication.externalPeers` gains/loses an
entry - the new list must land on every cluster's `helm upgrade` or the
mesh becomes asymmetric.

## Rollback

Helm rollback works for the chart itself:

```bash
helm rollback ldap 3 --namespace ldap        # go back to revision 3
```

Caveats:

- **Chart-managed passwords are NOT rotated on rollback.** The lookup +
  fallback pattern keeps the current Secret in place regardless of
  which revision you land on.
- **Data on PVCs is NOT touched by rollback.** If a bad upgrade
  populated bad LDIF via the sync Jobs (removed users, wrong ppolicy),
  rolling back the chart doesn't undo those LDAP writes. Restore from
  backup instead - see [`backup-restore.md`](./backup-restore.md).
- **CronJob history** - the old CronJob spec comes back but any Job
  spawned by the newer spec keeps running to completion.

## Uninstall

### Clean uninstall

```bash
helm uninstall ldap --namespace ldap
```

What Helm deletes:
- Deployment, StatefulSet, Services, ConfigMaps, RBAC, Ingress,
  NetworkPolicy, PDB, CronJobs, PrometheusRule, ServiceMonitor,
  cert-manager Certificate CR.

What Helm KEEPS (annotated `helm.sh/resource-policy: keep`):
- `<release>-openldap-admin`
- `<release>-openldap-replicator` (HA modes)
- `<release>-openldap-user-*` (chart-generated per-user passwords)
- `<release>-openldap-tls` (when `tls.backend: job`)
- `<release>-phpldapadmin-app-key` + `<release>-phpldapadmin-bind`
- `<release>-self-service-password-keyphrase`

Rationale: re-installing the same release name preserves credentials.
External systems (client apps, syncrepl peers, ...) already know those
passwords and would break if the chart rotated them silently.

What Helm CANNOT clean up:
- **PVCs** created by the StatefulSet's `volumeClaimTemplates`
  (`data-<release>-openldap-N`). Kubernetes intentionally decouples
  their lifecycle from the StatefulSet.
- **PVC created for backups** (`<release>-openldap-backup`) IF
  `backup.persistence.existingClaim` was NOT used.

### Purge everything

Only when you really want a fresh start (dev, DR test):

```bash
NS=ldap
helm uninstall ldap -n $NS

# Delete kept Secrets
kubectl -n $NS delete secret \
  -l app.kubernetes.io/part-of=openldap-platform

# Delete PVCs (this DESTROYS every entry in LDAP)
kubectl -n $NS delete pvc \
  -l app.kubernetes.io/part-of=openldap-platform
kubectl -n $NS delete pvc data-ldap-openldap-0 \
  data-ldap-openldap-1 data-ldap-openldap-2 \
  --ignore-not-found

# Optionally drop the namespace
kubectl delete namespace $NS
```

### Partial uninstall (keep openldap, drop UIs)

```yaml
phpldapadmin:
  enabled: false
self-service-password:
  enabled: false
```

`helm upgrade` - Deployments and Services for the UIs get deleted;
openldap keeps running. Auto-generated UI Secrets stay (harmless).

## Version compatibility

See [`compatibility.md`](./compatibility.md).

## Values-schema migration

The chart is v0.1.0 and has no BC-breaking history yet. Any future
values-schema change will be announced with:
- The chart version's `Chart.yaml` `annotations.upgrade-notes` field.
- An entry in this file listing the affected values + migration
  command.

Rule of thumb until then: after `helm pull`ing a new chart version, run
`helm template ldap kubernetes/charts/openldap-platform -f my-values.yaml`
and diff against the previous render before applying.
