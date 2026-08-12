# Scaling the OpenLDAP writable pool

The chart supports **fully automatic** horizontal scaling of the
writable StatefulSet in `mode: multi-master` — including HPA-driven
scaling that never touches Helm values. Three orthogonal knobs:

1. **Manual** — set `openldap.replicaCount` and `helm upgrade`.
2. **HPA** — resource + custom-metric-driven autoscaling.
3. **`scaleSchedule`** — cron-driven adjustment of the HPA min/max
   window (business-hour ramp-up, off-hour cooldown).

All three end up on the same reconcile path: every pod's initContainer
rebuilds `cn=config`'s peer list against the LIVE `spec.replicas` and
the data database (`mdb`) is preserved.

## Constraints

- Only `mode: multi-master` scales. The chart fails render if you try
  `hpa.enabled=true` with `standalone` or `mirror` (both enforce fixed
  `replicaCount` — 1 and 2 respectively).
- `openldap.replicaCount` is the INITIAL count on first install; when
  the HPA is enabled it owns the count afterwards. Keep
  `replicaCount == hpa.minReplicas` so `helm upgrade` doesn't briefly
  scale down before the HPA rescales.
- `helm upgrade` after HPA has scaled the STS will **conflict** on
  `spec.replicas` (kube-controller-manager owns that field via HPA's
  `scale` subresource). Bump `openldap.replicaCount` to match the live
  count for that upgrade, or use `helm upgrade --force`. Not a
  chart bug — standard HPA/helm interop.
- With `replication.replicateConfig.enabled=true`, the peer topology
  (`olcServerID` URL list + `olcSyncRepl` entries) lives in `cn=config` and
  therefore replicates. `REPLICATE_CONFIG` is part of the topology hash, so a
  scale event still restarts every pod and each one rebuilds `cn=config`
  against the new `REPLICA_COUNT` — the replicated copy converges to the same
  content. Expect a short window during the rolling restart where pods
  disagree on the peer list; syncrepl retries until it closes.

## How full-auto reconcile works (two-part mechanism)

**Part A — bootstrap fetches live `spec.replicas` at boot**

In multi-master mode, every pod carries the SA token
(`automountServiceAccountToken: true`) and its bootstrap initContainer
queries the K8s API for the live `StatefulSet.spec.replicas` before
building the syncrepl peer list. The env `REPLICA_COUNT` (baked from
`.Values.replicaCount` at helm render) is used only as a fallback if
the API call fails.

Bootstrap trace on a scale event:

```
[bootstrap] REPLICA_COUNT env=2 — using live STS spec.replicas=3
[bootstrap] built 3 syncrepl providers, serverID=1
[bootstrap] Reconcile done — cn=config rebuilt for the new topology.
```

The RBAC scope for this is minimal — a Role `<release>-openldap-server`
with `statefulsets/get` bound to the exact STS name only, granted to
the openldap SA. Only rendered when `mode: multi-master`.

**Part B — scale-watcher Deployment triggers a rollout on scale events**

A 1-replica Deployment `<release>-openldap-scale-watcher` polls
`STS.spec.replicas` every 10 s (configurable via
`scaleWatcher.pollIntervalSeconds`). When it detects a change, it runs
`kubectl rollout restart sts <name>` — K8s then rolls existing pods so
they re-run bootstrap and, via Part A, discover the new count and
reconcile cn=config.

Watcher trace during a scale-down:

```
[scale-watcher] watching sts/ldap-openldap in ns/ldap (poll=10s)
[scale-watcher] spec.replicas changed 4 -> 2 — rolling restart
statefulset.apps/ldap-openldap restarted
```

Emitted only when `mode: multi-master` AND (`hpa.enabled` OR
`scaleSchedule`). Manual `helm upgrade --set replicaCount=N` doesn't
need it (the checksum on the PodTemplate flips → K8s rolls
automatically) but the watcher is harmless if left on.

**Bootstrap reconcile branch (rebuilds cn=config in-place)**

On each pod boot the initContainer:

1. Computes `DESIRED_TOPO_HASH` from `MODE | NODE_ROLE | REPLICA_COUNT
   | serverIdBase | READONLY_SERVER_ID_BASE | EXTERNAL_PEERS | SUFFIX`
   — where `REPLICA_COUNT` is the live value from Part A.
2. Compares to `${SLAPD_D}/.topology-hash`. If matches → fast path
   skip. If differs → wipes `${SLAPD_D}` only (data DB in `${MDB_DIR}`
   untouched), re-runs full bootstrap with the new inputs, writes the
   new hash + marker.
3. Mid-write crash safe (hash + marker written LAST → partial run
   forces another reconcile on next boot).

Declarative sync-Jobs (`overlays` / `acls` / `treeGrants` / `ppolicy`
/ `users` / `groups`) run as post-install/upgrade hooks and re-apply
everything they own on every helm upgrade, so any live cn=config
additions they manage are automatically restored after the reconcile
wipe. Manual `openldap-cli` edits made outside those blocks WILL be
lost on reconcile — put them under a declarative block if you want
them to survive scale events.

## Manual scaling

```bash
helm upgrade ldap kubernetes/charts/openldap-platform \
  --namespace ldap --reuse-values \
  --set openldap.replicaCount=5
```

Path: helm changes `.Values.replicaCount` → the `checksum/topology`
annotation on the PodTemplate flips → StatefulSet controller does a
rolling restart AND scales to N → every pod's bootstrap sees a
mismatched topology hash → reconcile branch fires.

Works even without the scale-watcher Deployment (the PodTemplate
checksum is enough). Data preserved.

## HPA — resource + custom metrics

```yaml
openldap:
  mode: multi-master
  replicaCount: 2        # initial + hpa.minReplicas

  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 6

    # metrics[] is the autoscaling/v2 spec verbatim.
    metrics:
      # Resource metrics (metrics-server must be present).
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
        stabilizationWindowSeconds: 600     # 10-minute grace period
        policies:
          - type: Pods
            value: 1
            periodSeconds: 300
      scaleUp:
        stabilizationWindowSeconds: 30
        policies:
          - type: Pods
            value: 2
            periodSeconds: 60
```

HPA-driven scale timeline:

1. HPA patches `sts/<name> subresource=scale spec.replicas` from N to M
   (M > N for scale-up, M < N for scale-down)
2. Within ≤ `scaleWatcher.pollIntervalSeconds` (default 10 s), the
   scale-watcher notices the change and runs `kubectl rollout restart`
3. StatefulSet controller rolls existing pods AND creates/terminates
   pods to match M
4. On each pod boot, bootstrap fetches live `spec.replicas=M` (Part A),
   sees hash mismatch, reconciles cn=config with M syncrepl providers
5. syncrepl catches up — new pods pull from the mesh, terminating pods
   finish their in-flight replication

End-to-end latency for scale-up: HPA control loop (~15 s) + watcher
poll (≤ 10 s) + rolling restart (~pod boot × N pods staggered) —
typically 90-180 s for a small mesh.

### Prometheus-backed custom metrics

`openldap.monitoring.enabled: true` runs the
[`openldap_prometheus_exporter`](https://github.com/maximewewer/openldap_prometheus_exporter)
sidecar and (optionally) a `ServiceMonitor` for prometheus-operator.
To scale on those metrics, you need **prometheus-adapter** (or
**KEDA**) in the cluster — it translates Prometheus queries into the
K8s custom / external metrics API that HPA consumes.

Example — scale up when the per-pod bind rate exceeds 200/s or search
p99 latency crosses 50 ms:

```yaml
openldap:
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
    metrics:
      # CPU floor safety net (metrics-server).
      - type: Resource
        resource:
          name: cpu
          target: { type: Utilization, averageUtilization: 75 }
      # Prometheus-adapter — Pods metric (per-pod scalar).
      - type: Pods
        pods:
          metric:
            name: openldap_bind_rate_per_second
          target:
            type: AverageValue
            averageValue: "200"
      # Prometheus-adapter — Object metric (query against a Service).
      - type: Object
        object:
          describedObject:
            apiVersion: v1
            kind: Service
            name: ldap-openldap
          metric:
            name: openldap_search_p99_ms
          target:
            type: Value
            value: "50"
```

Corresponding **prometheus-adapter rules** (installed alongside the
adapter — outside the chart's scope, kept here as reference):

```yaml
rules:
  - seriesQuery: 'openldap_bind_total{namespace!="",pod!=""}'
    resources:
      overrides:
        namespace: { resource: namespace }
        pod:       { resource: pod }
    name:
      matches: "^openldap_bind_total$"
      as:      "openldap_bind_rate_per_second"
    metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
```

**KEDA alternative** — install the KEDA operator, then use its
`ScaledObject` CRD instead of the native HPA (heavier dep, but supports
event-driven triggers Prometheus HPA can't do: pub/sub queue depth,
webhook, scheduled scaling with built-in cron trigger). The
scale-watcher still works — it observes `STS.spec.replicas` regardless
of who patches it.

## Time-of-day scaling — `scaleSchedule`

Chart-native (no KEDA/CronScaler required): each entry emits one
`CronJob` that runs `kubectl patch hpa` at its schedule to adjust the
HPA's min/max window. Perfect for a business-hour ramp-up + off-hour
cooldown when your workload has predictable daily peaks.

```yaml
openldap:
  hpa:
    enabled: true
    minReplicas: 2      # baseline (off-hours default)
    maxReplicas: 3

  scaleSchedule:
    - name: business-hours
      schedule: "0 8 * * 1-5"        # weekdays 08:00 UTC
      minReplicas: 4
      maxReplicas: 8
    - name: off-hours
      schedule: "0 20 * * 1-5"       # weekdays 20:00 UTC
      minReplicas: 2
      maxReplicas: 3
    - name: weekend
      schedule: "0 0 * * 6"          # Saturday 00:00 UTC
      minReplicas: 2
      maxReplicas: 2
    # Optional per-entry timezone (K8s 1.27+ with feature-gate
    # CronJobTimeZone GA in 1.27):
    #   timeZone: "Europe/Paris"
```

Each CronJob runs one `rancher/kubectl` container (distroless — invokes
`kubectl` directly with no shell), patches the HPA object, and exits.
The sync ServiceAccount is granted the
`autoscaling/horizontalpodautoscalers` verbs `get, patch` when
`scaleSchedule` is set.

**No conflict with the HPA itself** — the CronJob only sets the
min/max window; the HPA still owns the current replica count via its
metrics loop. When `minReplicas` bumps up, the HPA scales up on its
next control loop (~15 s), the scale-watcher notices, rolls pods; when
it drops down, the `behavior.scaleDown` stabilization window applies.

## Component summary

| Piece | Emit condition | Purpose |
|-------|----------------|---------|
| `checksum/topology` annotation on STS PodTemplate | `mode: multi-master` | Rolling restart on helm-value change |
| `automountServiceAccountToken: true` on STS pods | `mode: multi-master` | Bootstrap has SA token for API call |
| Role `<release>-openldap-server` (`statefulsets/get`) | `mode: multi-master` | RBAC for bootstrap's API query |
| `STS_NAME` env in bootstrap init | `mode: multi-master` | Target name for the API call |
| `HorizontalPodAutoscaler` | `hpa.enabled: true` | Metric-driven scale |
| `CronJob` × N (scaleSchedule) | `scaleSchedule[]` non-empty | Time-of-day min/max patch |
| `Deployment` scale-watcher | `mode: multi-master` AND (`hpa.enabled` OR `scaleSchedule`) | Bridges scale events (non-helm) to rolling restart |
| `statefulsets get,list,watch,patch` on sync SA | Watcher OR tls-renew rollingRestart | Watcher + TLS renew |
| `horizontalpodautoscalers get,patch` on sync SA | `scaleSchedule[]` non-empty AND `hpa.enabled` | Cron scaler patches HPA |

## Interaction with PodDisruptionBudget

The chart emits a PDB when `replicaCount > 1` with
`minAvailable = replicaCount - 1`. When the HPA drives the count up,
`minAvailable` stays computed against `replicaCount` — that's the value
at helm render time, NOT the live scale. If you want the PDB to track
the HPA range, override `podDisruptionBudget.minAvailable` with a
percentage form (e.g. `"50%"`) which auto-tracks live pod count.

Not the chart default because a fixed value is more predictable for
the standalone/mirror cases where scale doesn't move.

## PVC lifecycle on scale-down

StatefulSet retention policy defaults to keeping PVCs when pods are
removed (K8s `whenScaled: Retain`). Practical effect:

- Scale 3 → 2: pod-2 terminates, PVC-2 stays.
- Scale back 2 → 3: pod-2 re-attaches its retained PVC and skips seed
  (data still in `${MDB_DIR}`); reconcile branch rebuilds `cn=config`
  with the new topology and joins syncrepl.

To reclaim disk on permanent scale-down, delete the orphan PVCs
manually. If you want automatic cleanup, set
`persistentVolumeClaimRetentionPolicy.whenScaled: Delete` on the
StatefulSet (add via `openldap.extraDeploy` patch — not yet a
first-class chart knob).

## Troubleshooting

| Symptom | Check |
|---------|-------|
| HPA scales STS but existing pods still show old syncrepl count | scale-watcher pod status: `kubectl -n <ns> logs deploy/<release>-openldap-scale-watcher`. Should log the `spec.replicas changed X -> Y — rolling restart` line. If not, either the deployment isn't emitted (`hpa.enabled` + `scaleSchedule` both false in multi-master) or its poll hasn't fired yet (default 10 s). |
| New pods after HPA scale-up have wrong `REPLICA_COUNT` | Look for `[bootstrap] REPLICA_COUNT env=... — using live STS spec.replicas=...` in the pod's init log. If missing, the API call failed — check RBAC (`kubectl auth can-i get sts --as=system:serviceaccount:<ns>:<release>-openldap`) and that `automountServiceAccountToken: true` on the pod spec. |
| `helm upgrade` fails with `conflict with "kube-controller-manager"` on `spec.replicas` | Standard HPA+helm interop. Bump `openldap.replicaCount` in values to match the live STS count for this upgrade. |
| Pods rebooted but `olcSyncRepl` still points at old peers | initContainer log — should show `Topology changed` line. If it says `topology unchanged`, the Fix A API query returned the same value as before. Check `kubectl -n <ns> get sts <name> -o jsonpath='{.spec.replicas}'`. |
| New pod stuck in Init | initContainer log — likely LDIF template error (e.g. schema mismatch). Fall back: delete PVC on the stuck pod, let it seed fresh from ordinal-0. |
| HPA shows `<unknown>` for a Prometheus metric | prometheus-adapter not scraping / metric name mismatch. `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1` should list your metric. |
| CronJob scaler patched HPA but replicas didn't change | HPA needs a metrics-server reading to react. Wait one control loop (~15 s) or check HPA events for `FailedGetResourceMetric`. |
| Scale-down leaves noisy syncrepl retries in slapd logs | Expected briefly (~1-2 s) while the terminating pod finishes shutdown. Persistent errors after 1 min mean the reconcile didn't run — check initContainer logs on the surviving pods. |
| Scale-watcher pod OOMKilled after long uptime | Bump `scaleWatcher.resources.limits.memory` (default 128Mi). Alpine + kubectl usually stays under 50Mi, but transient K8s API paging can spike. |
