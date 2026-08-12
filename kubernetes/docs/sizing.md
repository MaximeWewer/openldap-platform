# Sizing

Practical guidance for scaling the chart across users, traffic and DCs.
Numbers below are order-of-magnitude - measure on your workload.

## Chart-level knobs

| Knob | Default | When to bump |
|------|---------|--------------|
| `openldap.replicaCount` | 1 | Availability target (see [Mode](#mode-selection)) |
| `openldap.resources` | 100m / 256Mi | See [CPU + memory](#cpu--memory) |
| `openldap.persistence.size` | 10 GiB | See [Persistent storage](#persistent-storage) |
| `openldap.database.main.maxSizeBytes` | 1 GiB | See [LMDB mapsize](#lmdb-mapsize) |
| `openldap.database.accesslog.maxSizeBytes` | 1 GiB | Highest-traffic knob - see [accesslog sizing](#accesslog-sizing) |
| `openldap.accesslog.purge` | `07+00:00 01+00:00` | Retention vs disk pressure |
| `openldap.backup.persistence.size` | 20 GiB | See [Backup storage](#backup-storage) |

## Mode selection

| Users | RPS peak | Recommended mode | Notes |
|-------|----------|------------------|-------|
| < 1k | < 10 | `standalone` | Single node, no PDB required |
| 1k–50k | 10–500 | `mirror` (2 pods) | Client picks primary; failover on outage |
| 50k+ or multi-DC | 500+ or geo | `multi-master` (3+ pods) | Writes anywhere, mesh syncrepl |

Prefer 3-way multi-master over 4+ - sync amplification grows quadratic
with peer count (each peer replays every other peer's writes).

## CPU + memory

Baseline per replica (idle):
- **slapd**: ~20 MB RSS, negligible CPU
- **exporter sidecar**: ~15 MB RSS, ~5 mCPU

Under load (rough - measure on your workload):

| Concurrent binds/sec | slapd CPU | slapd RSS |
|----------------------|-----------|-----------|
| 100 | 200 mCPU | 100 MB |
| 500 | 800 mCPU | 300 MB |
| 2000 | 2000 mCPU | 800 MB |

memberOf recomputation on large groups can spike CPU during bulk
add-member operations - bound by group size × concurrent writes.

Recommendations:
- `resources.requests.cpu: 100m`, `resources.limits.cpu: 1000m` for most
  workloads.
- `resources.requests.memory` should cover the working set (index +
  hot pages). For 10k users, 256 MB is enough; for 100k+, bump to 1 GiB.
- LMDB mmaps the whole DB - memory pressure only matters for what's
  actively read. `pmap $(pidof slapd) | tail` on a hot pod shows the
  resident portion.

## Persistent storage

Single PVC per replica, split into 3 subPaths:

| SubPath | Grows with | Sizing rule |
|---------|-----------|-------------|
| `slapd.d/` | schema + overlay definitions (static) | < 5 MB - no impact |
| `openldap-data/` | User entries | ~1 KB per entry raw + ~30% index overhead |
| `accesslog-data/` | Every audited write / bind | See below |

For 100k users with 20 groups each: ~200 MB raw + indexes → 500 MB.

## LMDB mapsize

`olcDbMaxSize` (bytes) is the maximum on-disk MDB file size, not the
initial allocation. LMDB grows sparsely up to this cap, so setting it
high on a small tree costs no disk.

Rules of thumb:
- **Main DB**: allocate `4 × current size`. For 100k users, set
  `2 GiB`. Growing later needs `helm upgrade` + pod restart.
- **Accesslog DB**: allocate `2 × (writes/sec × avg entry size × retention seconds)`.
  See below.

Bump ONLY (never shrink - LMDB has no shrink). Once slapd starts with
a given mapsize, only a stop → change → start cycle applies a new one.
The chart's bootstrap ConfigMap is re-templated on `helm upgrade`, so
`values.database.main.maxSizeBytes` change + rolling restart works.

### `MDB_MAP_FULL` incident recipe

Slapd starts failing writes with `MDB_MAP_FULL`. Bind attempts return
`Invalid credentials (49)` because ppolicy can't update its counters.

Live fix (no downtime):

```bash
# 1. Bump mapsize in cn=config directly, then values.yaml + helm upgrade.
kubectl -n <ns> exec ldap-openldap-0 -c openldap -- \
  ldapmodify -x -H ldap://localhost:389 \
    -D cn=adminconfig,cn=config -w "$CFG_PW" <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: 4294967296
EOF

# 2. slapd picks up the new size at the next transaction. NO restart needed
#    for MDB expand - mdb_env_set_mapsize is called on next tx begin.

# 3. Commit the value change to values.yaml for durability:
#      openldap.database.main.maxSizeBytes: 4294967296
```

## Accesslog sizing

The accesslog DB is the #1 chart failure mode in prod. It grows with
every write (and every bind when `accesslog.ops` includes `bind`) and
LMDB does NOT reclaim space on delete - only slapd's periodic purge +
the chart's `openldap-cli ops accesslog-purge` CronJob reclaim it.

Formula:

```
accesslog_size_bytes ≈ writes_per_sec × avg_entry_bytes × retention_secs × 2
                            (2× factor accounts for MDB overhead + syncrepl session log)
```

Example: 10 writes/sec × 500 bytes × 7 days retention (604800 s)
       = 60 MB × 2 = 120 MB. Cap: 512 MiB.

For a bind-audit heavy load (500 binds/sec logged):
500 × 400 × 604800 × 2 = ~240 GB. Set:
- `accesslog.maxSizeBytes: 274877906944` (256 GiB)
- `accesslog.purge: 03+00:00 00+06:00` (purge every 3 h, keep 6 h)
- `accesslogPurgeJob.enabled: true` - weekly MDB reclaim

If you can afford it, DON'T log successful binds - `logSuccess: false`
and `ops: writes` cuts the DB by 10-100× on a typical workload:

```yaml
openldap:
  accesslog:
    ops: "writes"           # drop 'bind'
    logSuccess: false       # only failed binds anyway (ppolicy)
```

## Backup storage

Formula:

```
backup_pvc_size ≈ (data_dump_size + config_dump_size) × retention_days × 1.5
                     (1.5× for gzip variance + head-room)
```

Config dump is always small (< 100 KB). Data dump ≈ 60-70% of the LMDB
main DB size after gzip.

Example: 500 MB main DB → 350 MB gzipped dump. 30 days retention:
350 × 30 × 1.5 = 16 GB. Chart default 20 GiB is fine.

## Cross-cluster HA

Additional overhead per peer:
- **Egress bandwidth** = writes/sec × avg entry size. Small (~10 KB/s
  per writes/sec). Traffic is LDAPS on port 636.
- **Latency budget** = client write latency + peer sync-back RTT × N-1.
  Keep peers within the same region unless async consistency is fine.
- **Storage** - each cluster stores the FULL tree, same sizing applies.

Rule: don't cross more than 3 clusters in one mesh. Beyond that,
consider a hub-and-spoke topology with a single primary DC.

## Prometheus scrape

The exporter scrapes cn=Monitor on every collection interval. Cost:
- ~50 ms per scrape on a 10k-user tree (dominated by index enumeration).
- Bump `LDAP_UPDATE_EVERY` env var (default 15s) if scrapes contend.

## Sync Jobs

`users` sync scales linearly with `len(users)` + LDAP call latency
(~10 ms per user create/update on same-cluster LDAP). For 500 users:
~5 s of LDAP time + 15-30 s of Alpine boot / apk / CLI download.

Beyond 5000 users, consider:
- Splitting the values file into batches driven by separate releases.
- Using external-secrets to sync passwords from a proper IdM
  (Keycloak, HR system) instead of listing everyone in values.yaml.

## Ingress

- `ingress-nginx` SSL passthrough: TCP connection cost is negligible;
  cert lifecycle is handled elsewhere.
- Gateway API TLSRoute: same story.
- LDAPS traffic bypasses HTTP-level rate limiting - don't rely on
  nginx annotations to throttle LDAP.
