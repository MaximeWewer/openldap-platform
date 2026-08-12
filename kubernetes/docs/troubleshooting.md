# Troubleshooting

Real failure modes seen during chart development, with the exact
diagnostic commands and fixes.

## Server pod

### 1. `Init:CrashLoopBackOff` — bootstrap failing

Check the init container's log:

```bash
kubectl -n <ns> logs <pod> -c bootstrap
# or, if the container already restarted:
kubectl -n <ns> logs <pod> -c bootstrap --previous
```

Common causes:

| Log message | Cause | Fix |
|-------------|-------|-----|
| `Partial state detected (no success marker) — wiping and restarting` | Previous slapadd errored mid-run | Chart auto-recovers on next init pass. Watch a couple of restarts before intervening. |
| `str2entry: entry -1 has multiple DNs` | LDIF merge lost a blank line between entries — user extraConfig error | Compare the rendered `bootstrap` ConfigMap to the source template. |
| `Admin secrets missing under /secrets` | The `<release>-openldap-admin` Secret was deleted or references a wrong `existingSecret` | Re-create the Secret with keys `admin-password` + `config-admin-password` (base64) |
| `apk add failed after 5 attempts` | Alpine mirror unreachable / DNS broken | Check DNS + egress on the node (test `alpine:3.24` pod running `apk update`). |
| `Replicator secret missing under /replicator` | `mode != standalone` but replicator Secret absent | The chart creates it automatically unless `replication.replicator.existingSecret` is set. Verify it wasn't manually deleted. |

### 2. Main container `Error` / `CrashLoopBackOff` (init OK)

```bash
kubectl -n <ns> logs <pod> -c openldap
```

| Log | Cause | Fix |
|-----|-------|-----|
| `daemon: bind(8) failed errno=2` | `ldapi:///` socket path missing (removed in this chart) | Should never happen with the shipped statefulset; check for a values override modifying the `-h` arg. |
| `no serverID / URL match found` | `replication.replicateConfig.enabled=true` switches `olcServerID` to the URL form, and no listed URL matches a slapd listener | The chart pins `-h` to `ldap://<pod-fqdn>:<port> ldap://127.0.0.1:<port>` for exactly this reason. Check you haven't overridden `openldap.args` / `openldap.command`, and that `service.ldapPort` matches on both sides. With `replicateConfig` off the chart uses the single-int form and this cannot happen. |
| Read-only replica silently stops receiving entries | An entry uses an objectClass added at runtime on the writable pool; the RO consumer lacks the schema, its `schemachecking=on` syncrepl rejects the entry and the whole stream stalls — with `-d 0` nothing is logged | Set `replication.replicateConfig.enabled=true`: RO pods then replicate the `cn=schema` subtree. To confirm a stall, compare entry counts: `ldapsearch -b <suffix> dn \| grep -c '^dn:'` on a writable pod vs the RO pod |
| `<olcMultiProvider> database is not a shadow` | `olcMirrorMode`/`olcMultiProvider` on a database with no active `olcSyncrepl` | Every syncrepl provider was skipped. With URL-form `olcServerID`, slapd drops the provider matching its own identity URL — if that was the only one, none is left. Check `REPLICA_COUNT` reached the pod (bootstrap logs `built N syncrepl providers`). |
| slapd exits with no log | `readOnlyRootFilesystem: true` + a writable dir mount missing | Verify `/run/openldap` emptyDir mount is present. |
| `MDB_MAP_FULL: Environment mapsize limit reached` | Main or accesslog DB hit `olcDbMaxSize` | Bump the value under `openldap.database.main.maxSizeBytes` / `openldap.database.accesslog.maxSizeBytes` and `helm upgrade`. See [`sizing.md`](./sizing.md). |

### 3. Slapd Ready but binds fail with `Invalid credentials (49)`

- Confirm the password you're using matches what's stored:

  ```bash
  kubectl -n <ns> get secret <release>-openldap-admin \
    -o jsonpath='{.data.admin-password}' | base64 -d ; echo
  ```

- Try binding as the `configAdmin` DN (bypasses the main DB entirely) — if
  that works, the failure is data-side (ACL / user missing). If the config
  bind also fails, the Secret pushed into cn=config diverged from the
  Secret you're reading — usually the result of a partial bootstrap. Wipe
  the PVC and reinstall.

### 4. Bind returns `Server is unwilling to perform (53) — unauthenticated bind`

You passed an empty password (`-w ""`). Check env var interpolation in
the script that built the ldapsearch command.

## Sync Jobs (users / groups / ppolicy)

### 5. Sync Job fails immediately: `apk add: transient failure`

Alpine mirrors flapping. The scripts already retry 5×; if it still fails,
the node has no egress to `dl-cdn.alpinelinux.org`. Add a mirror override
via `openldap.cli.image` (custom image with tools pre-installed) or open
egress.

### 6. `openldap-cli user add`: `Error: accepts 1 arg(s), received N`

Values `users[].attrs` value contains a space and got word-split. The
chart wraps `--set k=v` args as separate tokens; if you're passing your
own values via helm `--set`, escape spaces or use a values file.

### 7. Group reconcile: `Attribute Or Value Exists`

Sync Job is trying to add a member that's already present. Symptom of a
stale group state after a partial run. Delete the group and let the Job
re-create it, or manually align via `openldap-cli group info <cn>`.

### 8. Drift step deletes users you didn't expect

The users sync uses the Secret label
`openldap.platform/release=<release>,app.kubernetes.io/component=user-credentials`
to identify "chart-owned" users. Anything with those labels but absent
from `openldap.users[]` gets deleted (or locked, per `onUserRemove`).
Solution: remove the Secret's label OR set `onUserRemove: lock`.

## Replication (HA)

### 9. Writes on one pod don't appear on another

```bash
# From INSIDE the LDAP net, check the replication state on every pod:
for i in 0 1 2; do
  echo "== pod $i =="
  kubectl -n <ns> exec ldap-openldap-$i -- \
    ldapsearch -x -LLL -H ldap://localhost:389 \
      -D cn=adminconfig,cn=config -w "$CFG_PW" \
      -b cn=config '(olcSyncrepl=*)' olcSyncrepl olcServerID | head -20
done
```

Common causes:

- **serverID collision** — two pods with the same ID freeze syncrepl.
  Check `replication.serverIdBase` — must be distinct across clusters.
- **Replicator bind failing** — check the replicator user exists on the
  seed DC (`ldap-openldap-user-replicator` is auto-created if HA is on):
  ```bash
  kubectl exec ldap-openldap-0 -- ldapsearch -x -LLL \
    -D "cn=replicator,ou=service-accounts,dc=example,dc=org" \
    -w "$REPL_PW" -H ldap://localhost:389 -b "" -s base '(objectClass=*)'
  ```
- **Peer network unreachable** — from a pod, `nc -zv <peer-fqdn> 636`.
  Cross-cluster: verify LDAPS ingress on the other cluster.
- **Clock skew > sessionLog window** — check node time is NTP-synced.

### 10. Cross-cluster peer refuses TLS

`openssl s_client -connect <peer>:636 -showcerts` from a debug pod. If
the peer's cert isn't signed by a CA in the local trust bundle, sync
fails silently. Every peer must trust the SAME CA — the shared-CA path
is documented in [`cross-cluster.md`](cross-cluster.md).

## TLS backend = job

### 11. `Could not read certificate from /tls/ca.crt` in renew job

Bracket-form JSONPath returns empty from kubectl. Chart uses dot-escaped
form (`{.data.ca\.crt}`) which works. If you customized the renew script,
avoid `{.data['ca.crt']}`.

### 12. Renew CronJob logs `nothing to do` forever

Expected when the cert is still valid past `renewThresholdDays`. Force a
renewal manually:

```bash
kubectl -n <ns> create job manual-renew \
  --from=cronjob/<release>-openldap-tls-renew
kubectl -n <ns> logs job/manual-renew
```

## phpLDAPadmin

### 13. Pod stuck `CreateContainerConfigError`: `image has non-numeric user`

The 2.x image's `init-docker` entrypoint refuses to run as `runAsNonRoot`
with a name-form USER (no numeric UID). Chart uses privileged sc by
default; if you enabled `runAsNonRoot`, remove it or pin `runAsUser: 0`.

### 14. `View path not found` in logs

You mounted an emptyDir at `/app/storage` (or `/app/bootstrap/cache`).
This hides shipped Laravel files. Don't mount there — accept
`readOnlyRootFilesystem: false` (chart default for this subchart).

## Self Service Password

### 15. SSP pod stuck: `Secret "ldap-openldap-user-ssp" not found`

Order-of-operations problem: SSP Deployment is a regular resource
(applied by Helm immediately) but its bind Secret is created by the
openldap post-install sync Job. Two fixes:

- **Don't use `--wait`** on the initial install — Kubernetes retries the
  Secret mount and the pod starts within ~30s of the sync Job completing.
- **Pre-provision the Secret via external-secrets** before installing.

### 16. SSP: `bind failed` at login

Log in as an existing LDAP user, not the bind account. Verify:
- `ldap.bind.dn` value is the actual FULL DN of an existing entry
- `ldap.bind.existingSecret` points at a Secret with the key matching
  `ldap.bind.secretKey` (defaults to `password` — matches openldap sync
  output; use `bindpw` if you copied from the phpldapadmin subchart pattern)

## Ingress

### 17. LDAPS ingress returns "empty reply" from `openssl s_client`

- **ingress-nginx**: controller not started with
  `--enable-ssl-passthrough`. Add the flag to the controller's args.
- **Gateway API**: the Gateway's TLS listener must have `mode: Passthrough`
  (chart default). If reusing an existing Gateway via
  `ingress.gatewayAPI.gatewayName`, verify its listener carries that mode.

### 18. phpLDAPadmin redirect loops

`APP_URL` doesn't match the browser URL. Chart auto-derives APP_URL from
`ingress.host` — if you have a proxy in front, override `app.url`
explicitly:

```yaml
phpldapadmin:
  app:
    url: https://ldap-admin.corp.example.com
```

## Prometheus exporter

### 19. `openldap_up{...} == 0` alert firing

Exporter can't bind to slapd. Check:

```bash
kubectl -n <ns> logs <pod> -c exporter | tail
```

Typical: config-admin password Secret was rotated but the pod wasn't
rolled. `kubectl rollout restart statefulset/<release>-openldap`.

### 20. Scrape target `Down` in Prometheus

- ServiceMonitor label mismatch — the `release: kube-prometheus-stack`
  label (or your prom-operator's serviceMonitorSelector) must match.
- Namespace scoping — `serviceMonitorNamespaceSelector` on the Prometheus
  CR must include the release namespace.

## NetworkPolicy

### 21. Traffic blocked after enabling NetworkPolicy

- CNI doesn't enforce NP: minikube default (`bridge`) is a no-op. Use
  Calico / Cilium / kube-router in prod.
- Missing allow rule: NetworkPolicy default-denies; add the client's
  selector under `networkPolicy.allowedFrom` or `networkPolicy.extraIngress`.
- External LDAPS peers unreachable in HA: chart opens `0.0.0.0/0:636`
  egress by default when `externalPeers` is set; tighten with
  `networkPolicy.externalPeerCIDRs` OR make sure your egress firewall
  permits it.

## Backup / restore

### 22. Backup CronJob logs `backup data -> /backup/data_.ldif.gz` (no date)

The `fileNamePattern` `{{ .date }}` placeholder wasn't substituted. Chart
runs the substitution at CronJob run time (`sed` on a shell-computed
DATE). If a custom pattern was set with a different placeholder, revert
to the default:

```yaml
openldap:
  backup:
    fileNamePattern: "{{ .kind }}_{{ .date }}.ldif.gz"
```

### 23. Backup PVC full

Retention deletes files older than `backup.retentionDays` (default 30).
Either bump the PVC size or lower the retention. `du -sh /backup/*` from
a debug pod tells you what's eating space (config dumps are tiny; data
dumps grow with the tree).

## Getting the raw slapd log

The container runs with `-d 0` (no debug). For a one-off deep-dive, bump
debug level and reload:

```bash
kubectl -n <ns> edit statefulset <release>-openldap
# find `-d 0` -> `-d config,stats,sync` (comma-separated per slapd(8))
# save; pod recycles; logs will be verbose.
```

Revert to `-d 0` when done — the verbose modes are chatty.
