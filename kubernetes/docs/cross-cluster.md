# Cross-cluster HA bootstrap

The chart supports N-way multi-master replication across independent
Kubernetes clusters - every cluster runs its own openldap-platform release,
and each peer syncs against the others through `replication.externalPeers`.

The steps below assume two data centres (`dc1`, `dc2`); scale the pattern to
more clusters by giving each one its own `serverIdBase`.

## Prerequisites (per cluster)

1. **LDAPS ingress reachable from the other clusters.** Whether you use
   ingress-nginx SSL passthrough, a Gateway API TLSRoute, or a bare
   `LoadBalancer` Service, port 636 has to accept traffic from every peer's
   egress IP. Publish a stable FQDN per cluster
   (`ldap.dc1.example.com`, `ldap.dc2.example.com`, …).
2. **Shared TLS trust.** Every peer needs to trust the same CA - the
   simplest path is a single self-signed CA distributed to each cluster as
   the `tls.provided` Secret. If you use `tls.backend: cert-manager` on
   each cluster, point every Issuer at the SAME external CA (for example
   a Vault PKI or an HSM-backed CA).
3. **Distinct `serverIdBase` per cluster.** olcServerID collisions freeze
   syncrepl. Convention below reserves a decade per cluster:

   | Cluster | serverIdBase | Server IDs (3 replicas) |
   |---------|--------------|--------------------------|
   | dc1 | 1 | 1, 2, 3 |
   | dc2 | 10 | 10, 11, 12 |
   | dc3 | 20 | 20, 21, 22 |

4. **Shared replicator credentials.** Every peer's syncrepl connects as
   `cn=replicator,ou=service-accounts,<suffix>` with the SAME password.
   Provision the same Secret (key `replicator-password`) on every cluster
   via external-secrets - see `values.replication.replicator.existingSecret`.

5. **`cn=config` replication stays inside each cluster.**
   `replication.replicateConfig.enabled` builds its syncrepl provider list
   from the in-cluster StatefulSet pods only, never from `externalPeers` -
   deliberately. `cn=config` carries the per-cluster `serverIdBase` and the
   per-cluster peer list, so replicating it across clusters would have each
   cluster overwrite the other's topology. Enable it per cluster if you want
   ACL/overlay/schema changes to propagate between the pods of that cluster;
   apply cross-cluster config changes once per cluster.

## Ordered bootstrap

Bring the clusters up one at a time. Only the first one seeds the
directory tree; every subsequent cluster starts empty and pulls the full
dataset from the peers via syncrepl.

### 1. dc1 - seed cluster

Values overlay:

```yaml
openldap:
  mode: multi-master
  replicaCount: 3
  directory:
    suffix: dc=example,dc=org
  replication:
    serverIdBase: 1
    seedOnOrdinalZeroOnly: true       # default - pod-0 in dc1 loads base data
    replicator:
      existingSecret: shared-replicator
    externalPeers:
      - ldaps://ldap.dc2.example.com:636
      - ldaps://ldap.dc3.example.com:636   # optional third DC
  tls:
    enabled: true
    backend: provided
    provided:
      secretName: shared-openldap-tls   # populated by external-secrets
  ingress:
    enabled: true
    mode: ingress-nginx
    host: ldap.dc1.example.com
```

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  -n ldap --create-namespace -f dc1-values.yaml
```

Wait for the 3 pods to be `Ready` and validate:

```bash
kubectl -n ldap exec ldap-openldap-0 -- \
  ldapsearch -x -H ldap://localhost:389 -b dc=example,dc=org dn | head
```

### 2. dc2 - joining cluster

Values overlay:

```yaml
openldap:
  mode: multi-master
  replicaCount: 3
  directory:
    suffix: dc=example,dc=org           # same suffix everywhere
  replication:
    serverIdBase: 10                    # distinct decade
    seedOnOrdinalZeroOnly: false        # DO NOT re-seed - pull from dc1
    replicator:
      existingSecret: shared-replicator
    externalPeers:
      - ldaps://ldap.dc1.example.com:636
      - ldaps://ldap.dc3.example.com:636
  tls:
    enabled: true
    backend: provided
    provided:
      secretName: shared-openldap-tls
  ingress:
    enabled: true
    mode: ingress-nginx
    host: ldap.dc2.example.com
```

`seedOnOrdinalZeroOnly: false` prevents pod-0 in dc2 from loading the base
LDIF locally - instead, syncrepl pulls the full tree from dc1 within a few
seconds of first bind.

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  -n ldap --create-namespace -f dc2-values.yaml
```

Verify replication landed:

```bash
kubectl -n ldap exec ldap-openldap-0 -- \
  ldapsearch -x -LLL -H ldap://localhost:389 \
    -D cn=admin,dc=example,dc=org -w "$(...)" \
    -b dc=example,dc=org dn | wc -l
# Should match dc1's count.
```

### 3. dc3+ - same pattern as dc2

Same overlay as dc2 with `serverIdBase: 20` and its own hostname.

## Adding a peer after the mesh is running

Every cluster's `externalPeers` list is static (baked into the running
`cn=config`). Adding a new DC therefore means a **rolling update on
every existing cluster** to include the new endpoint:

```yaml
# On dc1 + dc2 (and any other existing cluster):
openldap:
  replication:
    externalPeers:
      - ldaps://ldap.dc2.example.com:636
      - ldaps://ldap.dc3.example.com:636       # NEW
```

Then `helm upgrade` each cluster. The change re-templates the syncrepl
stanza and, in a future PR, a Helm hook will apply it via
`openldap-cli config set` without a slapd restart. Until that hook lands,
a rolling restart of the StatefulSet is required to reload cn=config.

## Removing a peer

Reverse the operation:

1. Drain writes from the leaving cluster (client-side).
2. `helm upgrade` every remaining cluster with the leaver stripped from
   `externalPeers`, then roll the StatefulSets.
3. `helm uninstall` the leaver.

## Split-brain avoidance

Multi-master resolves conflicts via delta-syncrepl's entryCSN comparison -
the write with the newest CSN wins. That is fine for eventual convergence
but does not protect against split-brain during network partitions. If two
DCs get partitioned and both accept writes on the SAME entry, the loser's
change is silently overwritten when connectivity comes back.

Mitigations:

- **Route writes to a single DC at a time** via GeoDNS + client
  affinity - every DC still accepts reads locally, but writes go through
  the "primary" DC. Switch the primary manually during DC-level failover.
- **Monitor `openldap_replication_lag_seconds`** (shipped by the
  Prometheus exporter - see `openldap.monitoring.enabled`). Alert on lag
  above a business-defined threshold.
- **Keep the accesslog purge conservative** - the syncrepl session log is
  sized off `accesslog.purge`; too aggressive a purge on a partitioned DC
  forces a full refresh instead of a delta once connectivity returns.

## Runbook - CA rotation across the mesh

Rotating the shared CA is the one operation that must span every cluster
in lockstep, because all peers must trust the new chain before any peer
starts serving with the new leaf certs.

1. Issue the new CA + per-node leaves out-of-band (Vault, offline CA, ...).
2. Push the **combined** CA bundle (old + new) to every cluster's TLS
   Secret. Every peer now trusts both chains.
3. Roll each cluster one at a time so pods pick up the new leaf certs
   (`kubectl rollout restart statefulset/ldap-openldap`). Peer connections
   are re-established with the new chain; the old chain still validates
   pending connections.
4. Once every cluster serves the new leaf, push the CA bundle without the
   old cert. Roll one more time to drop the old trust anchor.
