# Values reference

Auto-generated exhaustive tables (one per chart) via
[helm-docs](https://github.com/norwoodj/helm-docs) - every knob with its
current default, straight out of the chart's `values.yaml`:

- Umbrella: [`openldap-platform/README.md`](../charts/openldap-platform/README.md)
- openldap subchart: [`charts/openldap/README.md`](../charts/openldap-platform/charts/openldap/README.md)
- phpldapadmin subchart: [`charts/phpldapadmin/README.md`](../charts/openldap-platform/charts/phpldapadmin/README.md)
- self-service-password subchart: [`charts/self-service-password/README.md`](../charts/openldap-platform/charts/self-service-password/README.md)

Regenerate after touching a `values.yaml`:

```bash
cd kubernetes
make docs        # writes README.md in each chart directory
make docs-check  # CI-friendly staleness check
```

The umbrella `values.yaml` is a full mirror of every subchart's values
(all 3 nested under `openldap:`, `phpldapadmin:`, `self-service-password:`)
so the umbrella README ships a single table covering the whole stack
(~430 rows). Per-subchart READMEs cover the same knobs at their own
altitude and are useful when the subchart is installed standalone.

Description column is blank for freeform comments - helm-docs picks up
the ones prefixed with `# -- <description>` on the line above each key.
Convert commentary progressively as knobs stabilise.

Each chart carries a `README.md.gotmpl` template with the chart's own
custom sections (TL;DR, docs pointers) plus the standard helm-docs
placeholders (`chart.header`, `chart.valuesSection`, …). Regenerating is
non-destructive - the .gotmpl is the source of truth.

## Most-tuned values (curated)

Starting overlay if you want to skim before opening the full tables.

| Value | Default | Notes |
|-------|---------|-------|
| `openldap.mode` | `standalone` | `standalone` \| `mirror` \| `multi-master` |
| `openldap.replicaCount` | `1` | Must match `mode` (1/2/N≥2) |
| `openldap.readOnlyReplicas.count` | `0` | Additional read-only consumer pool |
| `openldap.directory.suffix` | `dc=example,dc=org` | Root of the tree |
| `openldap.directory.schemas` | `[cosine, inetorgperson, dyngroup]` | Add `nis` for POSIX accounts |
| `openldap.admin.bindDN` | `cn=admin,dc=example,dc=org` | rootDN of the main DB |
| `openldap.admin.existingSecret` | `""` | Point at ESO / SealedSecret in prod |
| `openldap.persistence.size` | `10Gi` | PVC size per replica |
| `openldap.database.main.maxSizeBytes` | 1 GiB | Bump for > 100k entries |
| `openldap.database.accesslog.maxSizeBytes` | 1 GiB | #1 prod incident source; size to writes/sec |
| `openldap.accesslog.ops` | `writes bind` | Drop `bind` for high-traffic setups |
| `openldap.replication.serverIdBase` | `1` | Distinct per cluster in cross-cluster HA |
| `openldap.replication.externalPeers` | `[]` | Cross-cluster LDAPS URIs |
| `openldap.replication.replicateConfig.enabled` | `false` | Replicate `cn=config` (ACLs, overlays, schema, ppolicy) between writable pods. Switches `olcServerID` to the URL form and pins slapd's `-h`. In-cluster peers only - never `externalPeers`. Read-only replicas get the `cn=schema` subtree only (prevents their syncrepl stalling on a runtime schema addition) |
| `openldap.hpa.enabled` | `false` | HorizontalPodAutoscaler v2 - requires `mode: multi-master` |
| `openldap.hpa.minReplicas` / `maxReplicas` | `2` / `5` | HPA scale window |
| `openldap.hpa.metrics` | CPU 70% + mem 80% | autoscaling/v2 metrics[] verbatim; supports Prometheus-adapter |
| `openldap.scaleSchedule` | `[]` | Cron CronJobs that patch HPA min/max at scheduled times |
| `openldap.scaleWatcher.pollIntervalSeconds` | `10` | Scale-watcher STS poll interval (auto-emitted with hpa / scaleSchedule) |
| `openldap.replication.startTLS` | `""` | `""` \| `"yes"` \| `"critical"` - quote to avoid YAML bool |
| `openldap.customSchemas.files` | `{}` | Inline extra schema LDIFs |
| `openldap.customLdifs.files` | `{}` | Inline extra data LDIFs (rendered via tpl) |
| `openldap.customAcls` | `[]` | REPLACE default ACLs (list of directives) |
| `openldap.extraAcls` | `[]` | APPEND to default ACLs |
| `openldap.tls.enabled` | `false` | Turn on before any prod use |
| `openldap.tls.backend` | `cert-manager` | `cert-manager` \| `job` \| `provided` |
| `openldap.ingress.enabled` | `false` | Only LDAPS is routed |
| `openldap.ingress.host` | `""` | Required when ingress is enabled |
| `openldap.backup.enabled` | `false` | Daily CronJob, PVC-backed |
| `openldap.monitoring.enabled` | `false` | Sidecar exporter + optional SM/PR |
| `openldap.networkPolicy.enabled` | `false` | Default-deny + explicit allows |
| `openldap.podAntiAffinityPreset` | `""` | `""` \| `soft` \| `hard` - spread across nodes |
| `openldap.podDisruptionBudget.enabled` | `auto` | Enabled iff HA |
| `openldap.users` | `[]` | Declarative user list (sync Job reconciles) |
| `openldap.groups` | `[]` | Declarative group list |
| `openldap.policies` | `[]` | Declarative ppolicy templates |
| `openldap.onUserRemove` | `delete` | `delete` \| `lock` |
| `openldap.existingBootstrapConfigMap` | `""` | Escape hatch - full bootstrap CM override |
| `phpldapadmin.enabled` | `false` | UI subchart |
| `self-service-password.enabled` | `false` | End-user password UI |
