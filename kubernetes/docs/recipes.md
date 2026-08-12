# Recipes

Copy-paste `values.yaml` overlays for common shapes. Every recipe assumes
the chart is installed from a Git checkout as:

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  --namespace ldap --create-namespace \
  -f my-values.yaml
```

## 1. Dev / PoC - single pod, no TLS, no ingress

Fastest install for a local minikube / kind cluster. No credentials survive
uninstall unless you keep the release name (Secrets are annotated
`helm.sh/resource-policy: keep`).

```yaml
openldap:
  mode: standalone
  replicaCount: 1
  directory:
    suffix: dc=dev,dc=local
    organization: "Dev"
  users:
    - uid: alice
      givenName: Alice
      sn: Wonder
      mail: alice@dev.local
    - uid: bob
      givenName: Bob
      sn: Builder
      mail: bob@dev.local
  groups:
    - cn: devs
      description: Development team
      members: [alice, bob]

phpldapadmin:
  enabled: true       # port-forward svc/ldap-phpldapadmin 8080:8080
```

## 2. Small prod - mirror HA, cert-manager, backup, monitoring

Two-node active/passive on a single cluster, LDAPS via cert-manager,
nightly backups on a 20Gi PVC, Prometheus scrape.

```yaml
openldap:
  mode: mirror
  replicaCount: 2

  directory:
    suffix: dc=example,dc=org
    organization: "Example Corp"

  # Server hardening (defaults, shown here for clarity).
  networkPolicy:
    enabled: true
  podDisruptionBudget:
    enabled: auto              # minAvailable: 1 in mirror mode

  tls:
    enabled: true
    backend: cert-manager
    certManager:
      issuerRef: { name: internal-ca, kind: ClusterIssuer }
      dnsNames: [ldap.example.org]

  ingress:
    enabled: true
    mode: ingress-nginx
    host: ldap.example.org

  backup:
    enabled: true
    schedule: "0 22 * * *"
    retentionDays: 30
    persistence:
      size: 20Gi

  accesslogPurgeJob:
    enabled: true
    keepDays: 7

  monitoring:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: kube-prometheus-stack
    prometheusRule:
      enabled: true

  # Overlays, ppolicy, users, groups, ACLs and tree-scoped grants - all
  # reconciled on every helm upgrade by the sync Jobs (weight order:
  # overlays 4, ppolicy 5, acls 8, tree-grants 9, users 10, groups 15).
  # Drift removal for acls/treeGrants/overlays uses a chart-managed
  # ConfigMap `<release>-openldap-sync-state`.
  overlays:
    - name: memberof
      enable: true
    - name: refint
      enable: true
  policies:
    - cn: strong
      min-length: 14
      max-age: 7776000            # 90 days
      in-history: 5
      lockout: true
      max-failure: 5
      lockout-duration: 1800
  users:
    - uid: alice
      givenName: Alice
      sn: Admin
      mail: alice@example.org
      policy: strong
    - uid: bob
      givenName: Bob
      sn: Ops
      mail: bob@example.org
      policy: strong
  groups:
    - cn: admins
      description: LDAP admins
      members: [alice]
    - cn: ops
      description: Operations team
      members: [alice, bob]
    - cn: readers
      description: Read-only group
      members: [bob]
  acls:                                # openldap-cli config acl grant
    - name: readers-can-read-users
      target: ou=users,dc=example,dc=org
      group: readers
      access: read
  treeGrants:                          # openldap-cli svc grant (container + entry rules)
    - name: grafana-svc
      tree: ou=users,dc=example,dc=org
      access: read
  aclLintCronJob:                      # daily `config acl lint` - fails on shadowed rules
    enabled: true
    schedule: "0 6 * * *"
```

## 3. Multi-DC prod - 3 nodes × 2 clusters, external peers

Two Kubernetes clusters (`dc1`, `dc2`) run 3 replicas each, forming a
6-way multi-master mesh. Shared CA + shared replicator credentials
provisioned via external-secrets. See
[`cross-cluster.md`](cross-cluster.md) for the
bootstrap order.

**dc1 overlay:**

```yaml
openldap:
  mode: multi-master
  replicaCount: 3

  directory:
    suffix: dc=example,dc=org

  admin:
    existingSecret: openldap-admin-shared     # populated by ESO

  replication:
    serverIdBase: 1                            # IDs 1, 2, 3 in this cluster
    seedOnOrdinalZeroOnly: true                # dc1 is the seed DC
    replicator:
      existingSecret: openldap-replicator-shared
    externalPeers:
      - ldaps://ldap.dc2.example.org:636

  tls:
    enabled: true
    backend: provided                          # shared CA + per-node cert
    provided:
      secretName: openldap-tls-shared          # populated by ESO

  ingress:
    enabled: true
    mode: ingress-nginx
    host: ldap.dc1.example.org

  backup:
    enabled: true
  monitoring:
    enabled: true
    serviceMonitor: { enabled: true }
    prometheusRule: { enabled: true }
  networkPolicy:
    enabled: true
    externalPeerCIDRs:                         # tighten cross-cluster egress
      - 203.0.113.0/24                         # dc2 public range
```

**dc2 overlay** - same as dc1 with three flipped keys:

```yaml
openldap:
  replication:
    serverIdBase: 10                           # distinct decade
    seedOnOrdinalZeroOnly: false               # DO NOT re-seed - pull from dc1
    externalPeers:
      - ldaps://ldap.dc1.example.org:636
  ingress:
    host: ldap.dc2.example.org
```

## 4. GitOps-managed - Argo CD driving the chart

Chart values live in the same repo, split per environment. Argo CD
Application manifest at [`../gitops/argocd/application.yaml`](../gitops/argocd/application.yaml).

```yaml
# gitops/argocd/envs/prod/values.yaml
openldap:
  mode: multi-master
  replicaCount: 3
  admin:
    existingSecret: openldap-admin              # sealed-secret or ESO
  replication:
    replicator:
      existingSecret: openldap-replicator
  tls:
    enabled: true
    backend: cert-manager
    certManager:
      issuerRef: { name: internal-ca, kind: ClusterIssuer }
  ingress:
    enabled: true
    mode: gateway-api
    host: ldap.example.org
    gatewayAPI:
      gatewayClassName: cilium
  monitoring:
    enabled: true
    serviceMonitor:
      enabled: true
    prometheusRule:
      enabled: true
  backup:
    enabled: true
  networkPolicy:
    enabled: true

phpldapadmin:
  enabled: true
  ingress:
    enabled: true
    mode: gateway-api
    host: ldap-admin.example.org
    tls:
      enabled: true
      certManager:
        enabled: true
        issuerRef: { name: internal-ca, kind: ClusterIssuer }

self-service-password:
  enabled: true
  ldap:
    bind:
      dn: cn=ssp,ou=users,dc=example,dc=org
      existingSecret: ldap-openldap-user-ssp     # created by openldap sync
  ingress:
    enabled: true
    mode: gateway-api
    host: password.example.org
    tls:
      enabled: true
      certManager:
        enabled: true
        issuerRef: { name: internal-ca, kind: ClusterIssuer }
```

## 5. External Secrets integration

Every `existingSecret` knob in the chart accepts a Secret populated by
[external-secrets.io](https://external-secrets.io). Minimal example for
the admin passwords sourced from Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: openldap-admin
  namespace: ldap
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: openldap-admin
    creationPolicy: Owner
  data:
    - secretKey: admin-password
      remoteRef:
        key: secret/ldap/prod
        property: admin_password
    - secretKey: config-admin-password
      remoteRef:
        key: secret/ldap/prod
        property: config_admin_password
```

Then in `values.yaml`:

```yaml
openldap:
  admin:
    existingSecret: openldap-admin
```

The chart's auto-generated Secret is skipped entirely - the ExternalSecret
owns the material.

## 6. Multi-master + autoscaling (HPA + time-of-day)

Full-auto scale up/down of a multi-master mesh - CPU / memory driven,
with a business-hour ramp-up that raises the HPA ceiling every weekday.
See [`scaling.md`](scaling.md) for the mechanism deep dive.

```yaml
openldap:
  mode: multi-master
  replicaCount: 2               # initial + hpa.minReplicas - keep aligned
  replication:
    serverIdBase: 1

  # metrics-server MUST be running in the cluster for CPU/memory HPA.
  # For Prometheus-backed metrics (bind rate, latency), install
  # prometheus-adapter and extend hpa.metrics[] - see scaling.md.
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
    metrics:
      - type: Resource
        resource:
          name: cpu
          target: { type: Utilization, averageUtilization: 70 }
      - type: Resource
        resource:
          name: memory
          target: { type: Utilization, averageUtilization: 80 }
    behavior:
      scaleDown:
        stabilizationWindowSeconds: 600      # 10 min grace
        policies:
          - { type: Pods, value: 1, periodSeconds: 300 }
      scaleUp:
        stabilizationWindowSeconds: 30
        policies:
          - { type: Pods, value: 2, periodSeconds: 60 }

  # Business hours: raise the ceiling. Off-hours: tighten. Weekend: minimum.
  scaleSchedule:
    - name: business-hours
      schedule: "0 8 * * 1-5"
      minReplicas: 4
      maxReplicas: 8
    - name: off-hours
      schedule: "0 20 * * 1-5"
      minReplicas: 2
      maxReplicas: 3
    - name: weekend
      schedule: "0 0 * * 6"
      minReplicas: 2
      maxReplicas: 2
```

Emitted alongside the standard resources: 1 `HorizontalPodAutoscaler`,
3 `CronJob` (one per `scaleSchedule` entry), 1 `Deployment`
`<release>-openldap-scale-watcher` (bridges HPA scale events to a
rolling restart so existing pods reconcile their cn=config peer list).

**helm upgrade caveat**: once the HPA has scaled `sts.spec.replicas`,
subsequent `helm upgrade` runs will conflict on that field
(kube-controller-manager owns it). Bump `openldap.replicaCount` in
values to match the live count for each upgrade.
