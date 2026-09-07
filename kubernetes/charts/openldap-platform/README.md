# openldap-platform

Umbrella chart for the OpenLDAP platform - OpenLDAP server (HA-ready
StatefulSet + delta-syncrepl), phpLDAPadmin, and Self Service Password.
Declarative GitOps-friendly administration via openldap-cli
(https://github.com/maximewewer/openldap-cli).

## TL;DR

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  --namespace ldap --create-namespace
```

Then retrieve the auto-generated admin credentials:

```bash
kubectl -n ldap get secret ldap-openldap-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

## Bundled subcharts

| Subchart | Default | Purpose |
|----------|---------|---------|
| `openldap` | enabled  | OpenLDAP 2.6 server - StatefulSet, cn=config bootstrap, HA (standalone / mirror / multi-master), delta-syncrepl, TLS backends, backup, monitoring |
| `phpldapadmin` | disabled | Web UI for browsing / editing the directory |
| `self-service-password` | disabled | End-user password change / reset UI (LTB) |

Enable the UIs with `--set phpldapadmin.enabled=true` and/or
`--set self-service-password.enabled=true`.

## Documentation

- Recipes (dev PoC, small prod, multi-DC, GitOps): [`../../docs/recipes.md`](../../docs/recipes.md)
- Troubleshooting (23 real failure modes): [`../../docs/troubleshooting.md`](../../docs/troubleshooting.md)
- Upgrade / uninstall lifecycle: [`../../docs/upgrade-uninstall.md`](../../docs/upgrade-uninstall.md)
- Backup / DR playbook: [`../../docs/backup-restore.md`](../../docs/backup-restore.md)
- Sizing & MAP_FULL recipe: [`../../docs/sizing.md`](../../docs/sizing.md)
- Migrate from Docker Compose: [`../../docs/migrate-from-docker.md`](../../docs/migrate-from-docker.md)
- Scaling (HPA, cron-scaler, auto-reconcile): [`../../docs/scaling.md`](../../docs/scaling.md)
- K8s / CNI / optional-dep compatibility: [`../../docs/compatibility.md`](../../docs/compatibility.md)
- GitOps (Argo CD + Flux): [`../../gitops/`](../../gitops/)
- Cross-cluster HA bootstrap: [`../../docs/cross-cluster.md`](../../docs/cross-cluster.md)

## Regenerating this README

```bash
cd kubernetes
make docs        # helm-docs → per-chart README.md
make docs-check  # CI staleness check
```

## Requirements

Kubernetes: `>=1.27.0-0`

| Repository | Name | Version |
|------------|------|---------|
| file://charts/openldap | openldap | 2026.9.1 |
| file://charts/phpldapadmin | phpldapadmin | 2026.9.1 |
| file://charts/self-service-password | self-service-password | 2026.9.1 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| openldap.accesslog.logSuccess | bool | `false` |  |
| openldap.accesslog.ops | string | `"writes bind"` |  |
| openldap.accesslog.purge | string | `"07+00:00 01+00:00"` |  |
| openldap.accesslogPurgeJob.dryRun | bool | `false` |  |
| openldap.accesslogPurgeJob.enabled | bool | `false` |  |
| openldap.accesslogPurgeJob.keepDays | int | `7` |  |
| openldap.accesslogPurgeJob.resources.limits.cpu | string | `"500m"` |  |
| openldap.accesslogPurgeJob.resources.limits.memory | string | `"256Mi"` |  |
| openldap.accesslogPurgeJob.resources.requests.cpu | string | `"50m"` |  |
| openldap.accesslogPurgeJob.resources.requests.memory | string | `"64Mi"` |  |
| openldap.accesslogPurgeJob.schedule | string | `"0 3 * * 0"` |  |
| openldap.accesslogPurgeJob.sweep | string | `"00+06:00"` |  |
| openldap.aclLintCronJob.databases | list | `[]` |  |
| openldap.aclLintCronJob.enabled | bool | `false` |  |
| openldap.aclLintCronJob.resources.limits.cpu | string | `"500m"` |  |
| openldap.aclLintCronJob.resources.limits.memory | string | `"256Mi"` |  |
| openldap.aclLintCronJob.resources.requests.cpu | string | `"50m"` |  |
| openldap.aclLintCronJob.resources.requests.memory | string | `"64Mi"` |  |
| openldap.aclLintCronJob.schedule | string | `"0 6 * * *"` |  |
| openldap.acls | list | `[]` |  |
| openldap.admin.bindDN | string | `"cn=admin,dc=example,dc=org"` |  |
| openldap.admin.existingSecret | string | `""` |  |
| openldap.affinity | object | `{}` |  |
| openldap.args | list | `[]` |  |
| openldap.backup.enabled | bool | `false` |  |
| openldap.backup.fileNamePattern | string | `"{{ .kind }}_{{ .date }}.ldif.gz"` |  |
| openldap.backup.includeOperational | bool | `true` |  |
| openldap.backup.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| openldap.backup.persistence.annotations | object | `{}` |  |
| openldap.backup.persistence.enabled | bool | `true` |  |
| openldap.backup.persistence.existingClaim | string | `""` |  |
| openldap.backup.persistence.size | string | `"20Gi"` |  |
| openldap.backup.persistence.storageClass | string | `""` |  |
| openldap.backup.resources.limits.cpu | string | `"500m"` |  |
| openldap.backup.resources.limits.memory | string | `"512Mi"` |  |
| openldap.backup.resources.requests.cpu | string | `"50m"` |  |
| openldap.backup.resources.requests.memory | string | `"128Mi"` |  |
| openldap.backup.retentionDays | int | `30` |  |
| openldap.backup.s3.bucket | string | `""` |  |
| openldap.backup.s3.enabled | bool | `false` |  |
| openldap.backup.s3.endpoint | string | `""` |  |
| openldap.backup.s3.existingSecret | string | `""` |  |
| openldap.backup.s3.region | string | `""` |  |
| openldap.backup.schedule | string | `"0 22 * * *"` |  |
| openldap.cli.downloadUrl | string | `"https://github.com/maximewewer/openldap-cli/releases/download"` |  |
| openldap.cli.image.pullPolicy | string | `"IfNotPresent"` |  |
| openldap.cli.image.repository | string | `"alpine"` |  |
| openldap.cli.image.tag | string | `"3.24"` |  |
| openldap.cli.kubectlVersion | string | `"v1.36.2"` |  |
| openldap.cli.resources.limits.cpu | string | `"500m"` |  |
| openldap.cli.resources.limits.memory | string | `"256Mi"` |  |
| openldap.cli.resources.requests.cpu | string | `"50m"` |  |
| openldap.cli.resources.requests.memory | string | `"64Mi"` |  |
| openldap.cli.version | string | `"v2026.9.1"` |  |
| openldap.cli.waitForLdap.intervalSeconds | int | `3` |  |
| openldap.cli.waitForLdap.timeoutSeconds | int | `180` |  |
| openldap.command | list | `[]` |  |
| openldap.configAdmin.bindDN | string | `"cn=adminconfig,cn=config"` |  |
| openldap.customAcls | list | `[]` |  |
| openldap.customLdifs.existingConfigMap | string | `""` |  |
| openldap.customLdifs.files | object | `{}` |  |
| openldap.customSchemas.existingConfigMap | string | `""` |  |
| openldap.customSchemas.files | object | `{}` |  |
| openldap.database.accesslog.maxSizeBytes | int | `1073741824` |  |
| openldap.database.main.maxSizeBytes | int | `1073741824` |  |
| openldap.directory.description | string | `""` |  |
| openldap.directory.organization | string | `"Example Org"` |  |
| openldap.directory.organizationalUnits[0] | string | `"users"` |  |
| openldap.directory.organizationalUnits[1] | string | `"groups"` |  |
| openldap.directory.organizationalUnits[2] | string | `"service-accounts"` |  |
| openldap.directory.organizationalUnits[3] | string | `"policies"` |  |
| openldap.directory.schemas[0] | string | `"cosine"` |  |
| openldap.directory.schemas[1] | string | `"inetorgperson"` |  |
| openldap.directory.schemas[2] | string | `"dyngroup"` |  |
| openldap.directory.suffix | string | `"dc=example,dc=org"` |  |
| openldap.enabled | bool | `true` |  |
| openldap.existingBootstrapConfigMap | string | `""` |  |
| openldap.extraAcls | list | `[]` |  |
| openldap.extraDeploy | list | `[]` |  |
| openldap.extraEnv | list | `[]` |  |
| openldap.extraInitContainers | list | `[]` |  |
| openldap.extraVolumeMounts | list | `[]` |  |
| openldap.extraVolumes | list | `[]` |  |
| openldap.groups | list | `[]` |  |
| openldap.headlessService.annotations | object | `{}` |  |
| openldap.hpa.behavior | object | `{}` |  |
| openldap.hpa.enabled | bool | `false` |  |
| openldap.hpa.maxReplicas | int | `5` |  |
| openldap.hpa.metrics[0].resource.name | string | `"cpu"` |  |
| openldap.hpa.metrics[0].resource.target.averageUtilization | int | `70` |  |
| openldap.hpa.metrics[0].resource.target.type | string | `"Utilization"` |  |
| openldap.hpa.metrics[0].type | string | `"Resource"` |  |
| openldap.hpa.metrics[1].resource.name | string | `"memory"` |  |
| openldap.hpa.metrics[1].resource.target.averageUtilization | int | `80` |  |
| openldap.hpa.metrics[1].resource.target.type | string | `"Utilization"` |  |
| openldap.hpa.metrics[1].type | string | `"Resource"` |  |
| openldap.hpa.minReplicas | int | `2` |  |
| openldap.image.pullPolicy | string | `"IfNotPresent"` |  |
| openldap.image.repository | string | `"cleanstart/openldap"` |  |
| openldap.image.tag | string | `"2.6.13"` |  |
| openldap.ingress.enabled | bool | `false` |  |
| openldap.ingress.gatewayAPI.gatewayClassName | string | `""` |  |
| openldap.ingress.gatewayAPI.gatewayName | string | `""` |  |
| openldap.ingress.gatewayAPI.gatewayNamespace | string | `""` |  |
| openldap.ingress.gatewayAPI.listenerName | string | `"ldaps"` |  |
| openldap.ingress.gatewayAPI.port | int | `636` |  |
| openldap.ingress.host | string | `""` |  |
| openldap.ingress.ingressNginx.annotations | object | `{}` |  |
| openldap.ingress.ingressNginx.className | string | `"nginx"` |  |
| openldap.ingress.ingressNginx.sslPassthrough | bool | `true` |  |
| openldap.ingress.mode | string | `"ingress-nginx"` |  |
| openldap.initImage.packages | string | `"openldap openldap-clients openldap-back-mdb openldap-overlay-all"` |  |
| openldap.initImage.pullPolicy | string | `"IfNotPresent"` |  |
| openldap.initImage.repository | string | `"alpine"` |  |
| openldap.initImage.tag | string | `"3.24"` |  |
| openldap.livenessProbe.failureThreshold | int | `6` |  |
| openldap.livenessProbe.initialDelaySeconds | int | `30` |  |
| openldap.livenessProbe.periodSeconds | int | `30` |  |
| openldap.livenessProbe.tcpSocket.port | string | `"ldap"` |  |
| openldap.livenessProbe.timeoutSeconds | int | `5` |  |
| openldap.mode | string | `"standalone"` |  |
| openldap.monitoring.enabled | bool | `false` |  |
| openldap.monitoring.exporter.extraEnv | list | `[]` |  |
| openldap.monitoring.exporter.image.pullPolicy | string | `"IfNotPresent"` |  |
| openldap.monitoring.exporter.image.repository | string | `"ghcr.io/maximewewer/openldap_prometheus_exporter"` |  |
| openldap.monitoring.exporter.image.tag | string | `"2026.9.1"` |  |
| openldap.monitoring.exporter.port | int | `9330` |  |
| openldap.monitoring.exporter.resources.limits.cpu | string | `"200m"` |  |
| openldap.monitoring.exporter.resources.limits.memory | string | `"128Mi"` |  |
| openldap.monitoring.exporter.resources.requests.cpu | string | `"20m"` |  |
| openldap.monitoring.exporter.resources.requests.memory | string | `"32Mi"` |  |
| openldap.monitoring.prometheusRule.enabled | bool | `false` |  |
| openldap.monitoring.prometheusRule.labels | object | `{}` |  |
| openldap.monitoring.prometheusRule.rules.defaultsEnabled | bool | `true` |  |
| openldap.monitoring.serviceMonitor.enabled | bool | `false` |  |
| openldap.monitoring.serviceMonitor.interval | string | `"30s"` |  |
| openldap.monitoring.serviceMonitor.labels | object | `{}` |  |
| openldap.monitoring.serviceMonitor.metricRelabelings | list | `[]` |  |
| openldap.monitoring.serviceMonitor.relabelings | list | `[]` |  |
| openldap.monitoring.serviceMonitor.scrapeTimeout | string | `"10s"` |  |
| openldap.networkPolicy.allowedFrom | list | `[]` |  |
| openldap.networkPolicy.enabled | bool | `false` |  |
| openldap.networkPolicy.externalPeerCIDRs | list | `[]` |  |
| openldap.networkPolicy.extraEgress | list | `[]` |  |
| openldap.networkPolicy.extraIngress | list | `[]` |  |
| openldap.networkPolicy.prometheusNamespace | string | `""` |  |
| openldap.nodeAffinityPreset.key | string | `""` |  |
| openldap.nodeAffinityPreset.type | string | `""` |  |
| openldap.nodeAffinityPreset.values | list | `[]` |  |
| openldap.nodeSelector | object | `{}` |  |
| openldap.onGroupRemove | string | `"delete"` |  |
| openldap.onUserRemove | string | `"delete"` |  |
| openldap.overlays | list | `[]` |  |
| openldap.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| openldap.persistence.annotations | object | `{}` |  |
| openldap.persistence.enabled | bool | `true` |  |
| openldap.persistence.size | string | `"10Gi"` |  |
| openldap.persistence.storageClass | string | `""` |  |
| openldap.podAnnotations | object | `{}` |  |
| openldap.podAntiAffinityPreset | string | `""` |  |
| openldap.podDisruptionBudget.enabled | string | `"auto"` |  |
| openldap.podDisruptionBudget.maxUnavailable | string | `""` |  |
| openldap.podDisruptionBudget.minAvailable | string | `""` |  |
| openldap.podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` |  |
| openldap.podLabels | object | `{}` |  |
| openldap.podSecurityContext.fsGroup | int | `102` |  |
| openldap.podSecurityContext.runAsNonRoot | bool | `true` |  |
| openldap.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| openldap.policies | list | `[]` |  |
| openldap.ppolicy.defaultPolicyRDN | string | `"cn=defaultppolicy"` |  |
| openldap.ppolicy.enabled | bool | `true` |  |
| openldap.ppolicy.hashCleartext | bool | `true` |  |
| openldap.priorityClassName | string | `""` |  |
| openldap.readOnlyReplicas.affinity | object | `{}` |  |
| openldap.readOnlyReplicas.count | int | `0` |  |
| openldap.readOnlyReplicas.enforceReadOnly | bool | `true` |  |
| openldap.readOnlyReplicas.nodeSelector | object | `{}` |  |
| openldap.readOnlyReplicas.persistence.size | string | `""` |  |
| openldap.readOnlyReplicas.persistence.storageClass | string | `""` |  |
| openldap.readOnlyReplicas.podAnnotations | object | `{}` |  |
| openldap.readOnlyReplicas.podLabels | object | `{}` |  |
| openldap.readOnlyReplicas.priorityClassName | string | `""` |  |
| openldap.readOnlyReplicas.resources | object | `{}` |  |
| openldap.readOnlyReplicas.serverIdBase | int | `100` |  |
| openldap.readOnlyReplicas.service.annotations | object | `{}` |  |
| openldap.readOnlyReplicas.service.type | string | `"ClusterIP"` |  |
| openldap.readOnlyReplicas.tolerations | list | `[]` |  |
| openldap.readOnlyReplicas.topologySpreadConstraints | list | `[]` |  |
| openldap.readinessProbe.failureThreshold | int | `3` |  |
| openldap.readinessProbe.initialDelaySeconds | int | `5` |  |
| openldap.readinessProbe.periodSeconds | int | `10` |  |
| openldap.readinessProbe.tcpSocket.port | string | `"ldap"` |  |
| openldap.readinessProbe.timeoutSeconds | int | `3` |  |
| openldap.replicaCount | int | `1` |  |
| openldap.replication.externalPeers | list | `[]` |  |
| openldap.replication.replicateConfig.checkpoint | string | `"100 10"` |  |
| openldap.replication.replicateConfig.enabled | bool | `true` |  |
| openldap.replication.replicateConfig.sessionLog | int | `100` |  |
| openldap.replication.replicator.dn | string | `"cn=replicator,ou=service-accounts"` |  |
| openldap.replication.replicator.existingSecret | string | `""` |  |
| openldap.replication.retry | string | `"5 60 60 +"` |  |
| openldap.replication.seedOnOrdinalZeroOnly | bool | `true` |  |
| openldap.replication.serverIdBase | int | `1` |  |
| openldap.replication.startTLS | string | `""` |  |
| openldap.replication.syncprov.checkpoint | string | `"100 10"` |  |
| openldap.replication.syncprov.sessionLog | int | `500` |  |
| openldap.replication.tlsReqcert | string | `""` |  |
| openldap.resources.limits.cpu | string | `"1000m"` |  |
| openldap.resources.limits.memory | string | `"1Gi"` |  |
| openldap.resources.requests.cpu | string | `"100m"` |  |
| openldap.resources.requests.memory | string | `"256Mi"` |  |
| openldap.reuseOrphanedUserSecret | bool | `false` |  |
| openldap.scaleSchedule | list | `[]` |  |
| openldap.scaleWatcher.pollIntervalSeconds | int | `10` |  |
| openldap.scaleWatcher.resources.limits.cpu | string | `"100m"` |  |
| openldap.scaleWatcher.resources.limits.memory | string | `"128Mi"` |  |
| openldap.scaleWatcher.resources.requests.cpu | string | `"10m"` |  |
| openldap.scaleWatcher.resources.requests.memory | string | `"32Mi"` |  |
| openldap.secrets.backend | string | `"kubernetes"` |  |
| openldap.secrets.externalSecrets.pathPrefix | string | `""` |  |
| openldap.secrets.externalSecrets.secretStore.kind | string | `"ClusterSecretStore"` |  |
| openldap.secrets.externalSecrets.secretStore.name | string | `""` |  |
| openldap.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| openldap.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| openldap.securityContext.readOnlyRootFilesystem | bool | `true` |  |
| openldap.securityContext.runAsGroup | int | `102` |  |
| openldap.securityContext.runAsUser | int | `101` |  |
| openldap.service.annotations | object | `{}` |  |
| openldap.service.clusterIP | string | `""` |  |
| openldap.service.enableLdapPort | bool | `true` |  |
| openldap.service.enableLdapsPort | bool | `true` |  |
| openldap.service.externalTrafficPolicy | string | `""` |  |
| openldap.service.ipFamilies | list | `[]` |  |
| openldap.service.ipFamilyPolicy | string | `""` |  |
| openldap.service.ldapNodePort | string | `""` |  |
| openldap.service.ldapPort | int | `389` |  |
| openldap.service.ldapsNodePort | string | `""` |  |
| openldap.service.ldapsPort | int | `636` |  |
| openldap.service.loadBalancerIP | string | `""` |  |
| openldap.service.loadBalancerSourceRanges | list | `[]` |  |
| openldap.service.type | string | `"ClusterIP"` |  |
| openldap.serviceAccount.annotations | object | `{}` |  |
| openldap.serviceAccount.automountServiceAccountToken | bool | `false` |  |
| openldap.serviceAccount.create | bool | `true` |  |
| openldap.serviceAccount.name | string | `""` |  |
| openldap.sidecars | list | `[]` |  |
| openldap.staleUserSecretCleanup.dryRun | bool | `false` |  |
| openldap.staleUserSecretCleanup.enabled | bool | `false` |  |
| openldap.staleUserSecretCleanup.resources.limits.cpu | string | `"500m"` |  |
| openldap.staleUserSecretCleanup.resources.limits.memory | string | `"256Mi"` |  |
| openldap.staleUserSecretCleanup.resources.requests.cpu | string | `"50m"` |  |
| openldap.staleUserSecretCleanup.resources.requests.memory | string | `"64Mi"` |  |
| openldap.staleUserSecretCleanup.schedule | string | `"30 3 * * *"` |  |
| openldap.startupProbe.failureThreshold | int | `60` |  |
| openldap.startupProbe.initialDelaySeconds | int | `5` |  |
| openldap.startupProbe.periodSeconds | int | `5` |  |
| openldap.startupProbe.tcpSocket.port | string | `"ldap"` |  |
| openldap.startupProbe.timeoutSeconds | int | `3` |  |
| openldap.tls.backend | string | `"cert-manager"` |  |
| openldap.tls.certManager.dnsNames | list | `[]` |  |
| openldap.tls.certManager.duration | string | `"8760h"` |  |
| openldap.tls.certManager.issuerRef.kind | string | `"ClusterIssuer"` |  |
| openldap.tls.certManager.issuerRef.name | string | `""` |  |
| openldap.tls.certManager.renewBefore | string | `"720h"` |  |
| openldap.tls.disallowPlainBind | bool | `false` |  |
| openldap.tls.enabled | bool | `false` |  |
| openldap.tls.job.caValidityDays | int | `3650` |  |
| openldap.tls.job.certValidityDays | int | `365` |  |
| openldap.tls.job.commonName | string | `""` |  |
| openldap.tls.job.image.pullPolicy | string | `"IfNotPresent"` |  |
| openldap.tls.job.image.repository | string | `"alpine"` |  |
| openldap.tls.job.image.tag | string | `"3.24"` |  |
| openldap.tls.job.renewThresholdDays | int | `30` |  |
| openldap.tls.job.resources.limits.cpu | string | `"200m"` |  |
| openldap.tls.job.resources.limits.memory | string | `"128Mi"` |  |
| openldap.tls.job.resources.requests.cpu | string | `"20m"` |  |
| openldap.tls.job.resources.requests.memory | string | `"32Mi"` |  |
| openldap.tls.job.rollingRestartOnRenew | bool | `true` |  |
| openldap.tls.job.schedule | string | `"0 4 * * 1"` |  |
| openldap.tls.job.subjectAltNames | list | `[]` |  |
| openldap.tls.minSSF | int | `0` |  |
| openldap.tls.provided.secretName | string | `""` |  |
| openldap.tolerations | list | `[]` |  |
| openldap.topologySpreadConstraints | list | `[]` |  |
| openldap.treeGrants | list | `[]` |  |
| openldap.users | list | `[]` |  |
| phpldapadmin.affinity | object | `{}` |  |
| phpldapadmin.app.keyExistingSecret | string | `""` |  |
| phpldapadmin.app.timezone | string | `"UTC"` |  |
| phpldapadmin.app.url | string | `"http://localhost:8080"` |  |
| phpldapadmin.bind.existingSecret | string | `""` |  |
| phpldapadmin.bind.username | string | `""` |  |
| phpldapadmin.enabled | bool | `false` |  |
| phpldapadmin.extraDeploy | list | `[]` |  |
| phpldapadmin.extraEnv | list | `[]` |  |
| phpldapadmin.extraInitContainers | list | `[]` |  |
| phpldapadmin.extraVolumeMounts | list | `[]` |  |
| phpldapadmin.extraVolumes | list | `[]` |  |
| phpldapadmin.image.pullPolicy | string | `"IfNotPresent"` |  |
| phpldapadmin.image.repository | string | `"phpldapadmin/phpldapadmin"` |  |
| phpldapadmin.image.tag | string | `"2.3.11"` |  |
| phpldapadmin.ingress.enabled | bool | `false` |  |
| phpldapadmin.ingress.gatewayAPI.gatewayClassName | string | `""` |  |
| phpldapadmin.ingress.gatewayAPI.gatewayName | string | `""` |  |
| phpldapadmin.ingress.gatewayAPI.gatewayNamespace | string | `""` |  |
| phpldapadmin.ingress.gatewayAPI.listenerName | string | `"https"` |  |
| phpldapadmin.ingress.gatewayAPI.port | int | `443` |  |
| phpldapadmin.ingress.host | string | `""` |  |
| phpldapadmin.ingress.ingressNginx.annotations | object | `{}` |  |
| phpldapadmin.ingress.ingressNginx.className | string | `"nginx"` |  |
| phpldapadmin.ingress.mode | string | `"ingress-nginx"` |  |
| phpldapadmin.ingress.tls.certManager.enabled | bool | `false` |  |
| phpldapadmin.ingress.tls.certManager.issuerRef.kind | string | `"ClusterIssuer"` |  |
| phpldapadmin.ingress.tls.certManager.issuerRef.name | string | `""` |  |
| phpldapadmin.ingress.tls.enabled | bool | `false` |  |
| phpldapadmin.ingress.tls.existingSecret | string | `""` |  |
| phpldapadmin.ldap.baseDN | string | `"dc=example,dc=org"` |  |
| phpldapadmin.ldap.connection | string | `"ldap"` |  |
| phpldapadmin.ldap.host | string | `""` |  |
| phpldapadmin.ldap.loginAttr | string | `"uid"` |  |
| phpldapadmin.ldap.port | int | `389` |  |
| phpldapadmin.livenessProbe.httpGet.path | string | `"/"` |  |
| phpldapadmin.livenessProbe.httpGet.port | string | `"http"` |  |
| phpldapadmin.livenessProbe.initialDelaySeconds | int | `30` |  |
| phpldapadmin.livenessProbe.periodSeconds | int | `30` |  |
| phpldapadmin.nodeSelector | object | `{}` |  |
| phpldapadmin.podAnnotations | object | `{}` |  |
| phpldapadmin.podLabels | object | `{}` |  |
| phpldapadmin.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| phpldapadmin.readinessProbe.httpGet.path | string | `"/"` |  |
| phpldapadmin.readinessProbe.httpGet.port | string | `"http"` |  |
| phpldapadmin.readinessProbe.initialDelaySeconds | int | `5` |  |
| phpldapadmin.readinessProbe.periodSeconds | int | `10` |  |
| phpldapadmin.replicaCount | int | `1` |  |
| phpldapadmin.resources.limits.cpu | string | `"500m"` |  |
| phpldapadmin.resources.limits.memory | string | `"512Mi"` |  |
| phpldapadmin.resources.requests.cpu | string | `"50m"` |  |
| phpldapadmin.resources.requests.memory | string | `"128Mi"` |  |
| phpldapadmin.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| phpldapadmin.securityContext.capabilities.add[0] | string | `"CHOWN"` |  |
| phpldapadmin.securityContext.capabilities.add[1] | string | `"SETUID"` |  |
| phpldapadmin.securityContext.capabilities.add[2] | string | `"SETGID"` |  |
| phpldapadmin.securityContext.capabilities.add[3] | string | `"DAC_OVERRIDE"` |  |
| phpldapadmin.securityContext.capabilities.add[4] | string | `"FOWNER"` |  |
| phpldapadmin.securityContext.capabilities.add[5] | string | `"NET_BIND_SERVICE"` |  |
| phpldapadmin.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| phpldapadmin.securityContext.readOnlyRootFilesystem | bool | `false` |  |
| phpldapadmin.service.annotations | object | `{}` |  |
| phpldapadmin.service.port | int | `8080` |  |
| phpldapadmin.service.type | string | `"ClusterIP"` |  |
| phpldapadmin.serviceAccount.annotations | object | `{}` |  |
| phpldapadmin.serviceAccount.automountServiceAccountToken | bool | `false` |  |
| phpldapadmin.serviceAccount.create | bool | `true` |  |
| phpldapadmin.serviceAccount.name | string | `""` |  |
| phpldapadmin.sidecars | list | `[]` |  |
| phpldapadmin.tolerations | list | `[]` |  |
| phpldapadmin.topologySpreadConstraints | list | `[]` |  |
| self-service-password.affinity | object | `{}` |  |
| self-service-password.enabled | bool | `false` |  |
| self-service-password.extraConfig | string | `""` |  |
| self-service-password.extraDeploy | list | `[]` |  |
| self-service-password.extraEnv | list | `[]` |  |
| self-service-password.extraInitContainers | list | `[]` |  |
| self-service-password.extraVolumeMounts | list | `[]` |  |
| self-service-password.extraVolumes | list | `[]` |  |
| self-service-password.general.allowedLanguages[0] | string | `"en"` |  |
| self-service-password.general.allowedLanguages[1] | string | `"fr"` |  |
| self-service-password.general.debug | bool | `false` |  |
| self-service-password.general.keyphraseExistingSecret | string | `""` |  |
| self-service-password.general.language | string | `"en"` |  |
| self-service-password.image.pullPolicy | string | `"IfNotPresent"` |  |
| self-service-password.image.repository | string | `"ltbproject/self-service-password"` |  |
| self-service-password.image.tag | string | `"1.8.1"` |  |
| self-service-password.ingress.enabled | bool | `false` |  |
| self-service-password.ingress.gatewayAPI.gatewayClassName | string | `""` |  |
| self-service-password.ingress.gatewayAPI.gatewayName | string | `""` |  |
| self-service-password.ingress.gatewayAPI.gatewayNamespace | string | `""` |  |
| self-service-password.ingress.gatewayAPI.listenerName | string | `"https"` |  |
| self-service-password.ingress.gatewayAPI.port | int | `443` |  |
| self-service-password.ingress.host | string | `""` |  |
| self-service-password.ingress.ingressNginx.annotations | object | `{}` |  |
| self-service-password.ingress.ingressNginx.className | string | `"nginx"` |  |
| self-service-password.ingress.mode | string | `"ingress-nginx"` |  |
| self-service-password.ingress.tls.certManager.enabled | bool | `false` |  |
| self-service-password.ingress.tls.certManager.issuerRef.kind | string | `"ClusterIssuer"` |  |
| self-service-password.ingress.tls.certManager.issuerRef.name | string | `""` |  |
| self-service-password.ingress.tls.enabled | bool | `false` |  |
| self-service-password.ingress.tls.existingSecret | string | `""` |  |
| self-service-password.ldap.baseDN | string | `"dc=example,dc=org"` |  |
| self-service-password.ldap.bind.dn | string | `"cn=ssp,ou=users,dc=example,dc=org"` |  |
| self-service-password.ldap.bind.existingSecret | string | `""` |  |
| self-service-password.ldap.bind.secretKey | string | `"password"` |  |
| self-service-password.ldap.connection | string | `"ldap"` |  |
| self-service-password.ldap.host | string | `""` |  |
| self-service-password.ldap.loginAttribute | string | `"uid"` |  |
| self-service-password.ldap.port | int | `389` |  |
| self-service-password.ldap.tls.caExistingSecret | string | `""` |  |
| self-service-password.ldap.tls.reqcert | string | `"hard"` |  |
| self-service-password.livenessProbe.httpGet.path | string | `"/"` |  |
| self-service-password.livenessProbe.httpGet.port | string | `"http"` |  |
| self-service-password.livenessProbe.initialDelaySeconds | int | `15` |  |
| self-service-password.livenessProbe.periodSeconds | int | `30` |  |
| self-service-password.mail.from | string | `""` |  |
| self-service-password.mail.fromName | string | `""` |  |
| self-service-password.mail.smtpAuth | bool | `false` |  |
| self-service-password.mail.smtpHost | string | `""` |  |
| self-service-password.mail.smtpPasswordExistingSecret | string | `""` |  |
| self-service-password.mail.smtpPasswordKey | string | `"password"` |  |
| self-service-password.mail.smtpPort | int | `587` |  |
| self-service-password.mail.smtpSecure | string | `"tls"` |  |
| self-service-password.mail.smtpUser | string | `""` |  |
| self-service-password.nodeSelector | object | `{}` |  |
| self-service-password.passwordPolicy.diffLastMinChars | int | `2` |  |
| self-service-password.passwordPolicy.hash | string | `"auto"` |  |
| self-service-password.passwordPolicy.maxLength | int | `64` |  |
| self-service-password.passwordPolicy.minDigit | int | `1` |  |
| self-service-password.passwordPolicy.minLength | int | `12` |  |
| self-service-password.passwordPolicy.minLower | int | `1` |  |
| self-service-password.passwordPolicy.minSpecial | int | `1` |  |
| self-service-password.passwordPolicy.minUpper | int | `1` |  |
| self-service-password.passwordPolicy.noReuse | bool | `true` |  |
| self-service-password.passwordPolicy.noSpecialAtEnds | bool | `true` |  |
| self-service-password.passwordPolicy.showPolicy | string | `"always"` |  |
| self-service-password.passwordPolicy.showPolicyPos | string | `"above"` |  |
| self-service-password.passwordPolicy.specialChars | string | `"^a-zA-Z0-9"` |  |
| self-service-password.passwordPolicy.usePwnedPasswords | bool | `false` |  |
| self-service-password.podAnnotations | object | `{}` |  |
| self-service-password.podLabels | object | `{}` |  |
| self-service-password.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| self-service-password.readinessProbe.httpGet.path | string | `"/"` |  |
| self-service-password.readinessProbe.httpGet.port | string | `"http"` |  |
| self-service-password.readinessProbe.initialDelaySeconds | int | `5` |  |
| self-service-password.readinessProbe.periodSeconds | int | `10` |  |
| self-service-password.replicaCount | int | `1` |  |
| self-service-password.resources.limits.cpu | string | `"500m"` |  |
| self-service-password.resources.limits.memory | string | `"512Mi"` |  |
| self-service-password.resources.requests.cpu | string | `"50m"` |  |
| self-service-password.resources.requests.memory | string | `"128Mi"` |  |
| self-service-password.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| self-service-password.securityContext.capabilities.add[0] | string | `"CHOWN"` |  |
| self-service-password.securityContext.capabilities.add[1] | string | `"SETUID"` |  |
| self-service-password.securityContext.capabilities.add[2] | string | `"SETGID"` |  |
| self-service-password.securityContext.capabilities.add[3] | string | `"DAC_OVERRIDE"` |  |
| self-service-password.securityContext.capabilities.add[4] | string | `"NET_BIND_SERVICE"` |  |
| self-service-password.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| self-service-password.securityContext.readOnlyRootFilesystem | bool | `false` |  |
| self-service-password.service.annotations | object | `{}` |  |
| self-service-password.service.port | int | `80` |  |
| self-service-password.service.type | string | `"ClusterIP"` |  |
| self-service-password.serviceAccount.annotations | object | `{}` |  |
| self-service-password.serviceAccount.automountServiceAccountToken | bool | `false` |  |
| self-service-password.serviceAccount.create | bool | `true` |  |
| self-service-password.serviceAccount.name | string | `""` |  |
| self-service-password.sidecars | list | `[]` |  |
| self-service-password.tolerations | list | `[]` |  |
| self-service-password.topologySpreadConstraints | list | `[]` |  |
| self-service-password.useQuestions | bool | `false` |  |
| self-service-password.useSms | bool | `false` |  |
| self-service-password.useTokens | bool | `false` |  |
