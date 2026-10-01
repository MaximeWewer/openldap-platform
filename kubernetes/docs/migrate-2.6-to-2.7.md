# Migrating OpenLDAP 2.6 -> 2.7

OpenLDAP 2.7 changed the back-mdb on-disk format. A data directory written
under 2.6 makes slapd 2.7 refuse to start:

```
mdb_db_open: database "dc=example,dc=org" cannot be opened:
MDB_INVALID: File is not an LMDB file (-30793). Administrator intervention needed!
backend_startup_one (type=mdb, suffix="dc=example,dc=org"): bi_db_open failed! (-30793)
```

So this is a dump and reload onto an empty volume, not an in-place upgrade.

`scripts/openldap-migrate.sh` does it entirely over LDAP with
`openldap-cli`: no shell in the server image, no volume access, and no
matching `slapcat` / `slapadd` builds on either side. `backup restore` sends
the **Relax** control, so the password hashes are restored as they are and
users keep the credentials they already have.

`cn=config` is not migrated and does not need to be - the chart rebuilds it
from values on a first bootstrap, the compose stacks from their
`slapd-config.ldif`. `dump` records it anyway, as a reference to diff the new
tree against the old one.

## What does not carry over

* `entryUUID`, `entryCSN`, `contextCSN`. The restored tree is a **new**
  directory. Reseed every replica from it; do not leave one to syncrepl from
  a 2.6 peer.
* `pwdChangedTime` and the other ppolicy timers. With
  `staleUserSecretCleanup.enabled: true`, the per-user Secrets keep a marker
  that no longer matches, so the CronJob reads them as spent and deletes
  them. Hand out any credential you still need first.
* `memberOf` is recomputed by the overlay on the new server, so group
  membership comes back from the `member` values in the dump.

## Two ways to do it

| | |
|---|---|
| **Helm, automatic** | `majorUpgrade.enabled: true`. The chart dumps, rebuilds and reloads by itself on the `helm upgrade` that moves the major, and does nothing on any other upgrade. Jump to [Automatic](#automatic-helm). |
| **By hand** | `scripts/openldap-migrate.sh`, three phases you drive. Works against any server - Helm, Compose or otherwise. The procedure below. |

For a Compose stack there is a third: `docker/migrate-2.6-to-2.7.sh`, which
orchestrates the whole thing for a stack directory. See
[Docker Compose](#docker-compose).

## Procedure

### 1. Dump, as the database rootDN

slapd filters the dump through its ACLs. A non-root bind is handed the
entries and attributes it may read and nothing else - including, under the
usual `by self write` clause, exactly **one** `userPassword`: its own. The
script counts the accounts in the dump against the hashes in it and refuses
to continue when they disagree, which is the case that would otherwise
restore a directory full of accounts nobody can log into.

Kubernetes - port-forward the old release:

```bash
kubectl -n ldap port-forward svc/ldap-openldap 1389:389 &

kubectl -n ldap get secret ldap-openldap-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d > /tmp/adm.pw
chmod 600 /tmp/adm.pw

scripts/openldap-migrate.sh dump \
  --url ldap://127.0.0.1:1389 \
  --base-dn dc=example,dc=org \
  --bind-dn cn=admin,dc=example,dc=org \
  --password-file /tmp/adm.pw \
  --config-bind-dn cn=adminconfig,cn=config \
  --config-password-file /tmp/cfgadm.pw \
  ./migration
```

Docker Compose - point it straight at the published port:

```bash
scripts/openldap-migrate.sh dump \
  --url ldap://127.0.0.1:389 \
  --base-dn dc=example,dc=org \
  --bind-dn cn=admin,dc=example,dc=org \
  --password-file /tmp/adm.pw \
  ./migration
```

### 2. Stand up 2.7 on an EMPTY volume

Reusing the old PVC is the one thing that cannot work - that is the
`MDB_INVALID` above.

Install the 2.7 release under a new name (or delete the old PVCs first),
**without** `users` / `groups` / `policies` in values: those entries come
back from the dump, and leaving the sync Jobs on means they reconcile against
a tree that is still empty.

```bash
helm upgrade --install ldap27 kubernetes/charts/openldap-platform \
  -n ldap27 --create-namespace -f my-values-no-sync.yaml
```

Wait for pod-0 to be Ready. The bootstrap creates the dc entry and the OUs,
no users.

### 3. Restore and verify

```bash
kubectl -n ldap27 port-forward svc/ldap27-openldap 1390:389 &

scripts/openldap-migrate.sh restore \
  --url ldap://127.0.0.1:1390 --base-dn dc=example,dc=org \
  --bind-dn cn=admin,dc=example,dc=org --password-file /tmp/adm27.pw \
  ./migration

scripts/openldap-migrate.sh verify \
  --url ldap://127.0.0.1:1390 --base-dn dc=example,dc=org \
  --bind-dn cn=admin,dc=example,dc=org --password-file /tmp/adm27.pw \
  ./migration
```

`restore` stops if the target already holds users, and aborts on the first
failing entry: a half-restored directory is worse than a failed run.

`verify` re-dumps the target and compares it with the manifest written by
`dump` - entry count, account count, and the password hashes byte for byte,
since a matching count is not the same as matching values.

```
[migrate] entries   : 11 (source) -> 11 (target)
[migrate] pw hashes : 3 (source) -> 3 (target)
[migrate] every password hash carried over byte for byte
[migrate] migration verified
```

### 4. Put the sync Jobs back

Restore `users` / `groups` / `policies` in values and `helm upgrade`. They
reconcile on top of the restored tree.

Mind `onUserRemove` (default `delete`): the per-user Secrets carry
`helm.sh/resource-policy: keep` and survive, so the drift pass sees every uid
the old release ever created. A uid that has a surviving Secret but is no
longer declared in values is deleted. Check the declared list against
`kubectl get secrets -l app.kubernetes.io/component=user-credentials` before
that upgrade, or set `onUserRemove: lock` for the first one.

## Other 2.7 changes worth checking

* `olcRefintAttribute: member memberOf` - several names in one value was a
  deprecation warning in 2.6 and is a hard error in 2.7
  (`Please insert multiple names as separate olcRefintAttribute values`).
  The chart and the compose stacks already write one name per value.
* The `cleanstart/openldap` runtime and `-dev` images disagree on the `ldap`
  uid/gid (102:103 vs 101:102). It does not reach the chart, which runs
  `slapd` directly under `securityContext.runAsUser` and mounts its own
  `/run/openldap`; the compose scripts read the uid out of the image.


## Automatic (Helm)

```yaml
openldap:
  image:
    tag: "2.7.1"          # the bump that triggers it
  # The 2.7 image runs its ldap account as 102:103 where 2.6 used 101:102,
  # and /var/lib/openldap is 0700 for it. Without these three, slapd dies on
  # its own data volume with `olcDbDirectory: invalid path: Permission
  # denied`. The chart refuses to render the mismatch rather than let that
  # happen, so you will be told before anything runs.
  securityContext:
    runAsUser: 102
    runAsGroup: 103
  podSecurityContext:
    fsGroup: 103
  majorUpgrade:
    enabled: true
```

### Why no init-image bump is needed

The data directory is seeded by `slapadd` out of `image` itself, in two init
containers between the renderer and the finalizer:

```
bootstrap      (initImage)    renders /rendered/{config,data}.ldif, hashes, decides, wipes
slapadd-config (image)        slapadd -n 0 -l /rendered/config.ldif
slapadd-data   (image)        slapadd -n 1 -l /rendered/data.ldif
finalize       (initImage)    chown, then the topology hash and the success marker
```

So the binary that writes the database is, by construction, the one slapd
will read it with - there is no second image tracking the server's version
and no tooling skew to keep in step. An empty rendered file is a clean no-op
for `slapadd`, which is how "nothing to seed" (HA ordinal != 0, read-only
pods, reconcile, topology unchanged) reaches a container that has no shell to
branch in.

The markers are written by the finalizer rather than the renderer: earlier
they would claim a directory `slapadd` had not filled yet, and a failed load
would leave it flagged as successfully bootstrapped and skipped forever after.

One behaviour changed with the split: `customLdifs` used to get one `slapadd`
per file, so a bad file only wasted itself. They are now concatenated into one
batch, so a bad file fails the whole load.

`helm upgrade` then runs, in hook order:

| | | |
|---|---|---|
| `-30` | `pre-upgrade` PVC | `<release>-openldap-migration`, carrying `helm.sh/resource-policy: keep` so the dump outlives the release. |
| `-25` | `pre-upgrade` Job `migrate-dump` | Reads the RUNNING server's version off `cn=Monitor`. Same major → deletes any stale migration state and exits. Different major → dumps the tree over LDAP as the rootDN onto the PVC and publishes a `<release>-openldap-migration-state` ConfigMap. A failure here fails the upgrade, with nothing touched. |
| | bootstrap init container | Compares the major stamped on the data directory with the one it is about to run. On a change it demands a migration state naming **this** release, **this** suffix, the major it is moving **to**, and a non-empty dump - then rebuilds the directory empty. Anything else and it stops, data intact. |
| `2` | `post-upgrade` Job `migrate-restore` | Reloads the dump, then checks the entry count and the pre-hashed passwords against the manifest. Runs before the sync Jobs (ppolicy 5, users 10, groups 15) so they reconcile on top of restored data. |

### Two things to get right before running it

**Use `helm upgrade --wait`.** Helm fires `post-upgrade` hooks as soon as the
resources are applied, not when the rollout finishes. Without `--wait` the
Service can still be answering from a pod on the old version with the old
data. The restore Job checks what is actually answering and refuses rather
than merge two directories, so the failure is safe - but it is a failed
upgrade you then have to re-run. In HA it matters more: while the StatefulSet
rolls, the Service fronts pods on both versions, and only `--wait` removes
that window.

**The mirrored image must be pullable by the cluster.** The chart points at
`ghcr.io/<owner>/openldap`. A GHCR package is private by default - either make
it public, or set `imagePullSecrets`. The slapadd init containers use the same
image, so a pull failure stops the pod before slapd is ever reached.

Nothing in that chain acts on a guess:

* The dump Job asks the live server its version rather than trusting values,
  so a patch bump, a values-only change or a re-run is a no-op.
* The bootstrap refuses to wipe on a state it cannot match to this release,
  and refuses equally when the major changed and there is **no** state - the
  pod stops with both versions named instead of crash-looping on
  `MDB_INVALID`.
* `majorUpgrade.maxDumpAgeMinutes` (default 120) stops a forgotten dump from
  quietly rolling the directory back to whenever it was taken.
* The restore refuses a directory that still holds users, which is what a
  wipe that did not happen looks like.

Left at `enabled: false`, a major bump fails the bootstrap with a message
naming both versions and the data is untouched - roll `image.tag` back and
nothing is lost.

The monitor database must be enabled (it is, by default): without it the dump
Job cannot tell what is running and stops rather than guess.

### Afterwards

The dump stays on the migration PVC. It holds password hashes - delete the
PVC once the release has proven itself.

In HA, every replica is reseeded from the reloaded tree. `contextCSN` is not
carried over, so a 2.7 node must never be left to syncrepl from a 2.6 peer:
upgrade the whole mesh in one go.

## Docker Compose

```bash
export LDAP_ADMIN_PASSWORD=...  LDAP_CONFIG_PASSWORD=...
docker/migrate-2.6-to-2.7.sh standalone
```

It reads the running version the same way, stops if there is nothing to do,
and otherwise dumps, stops the stack, moves `./data` aside (renamed, never
deleted), rebuilds `cn=config` **with the target image's own slapadd**,
repoints `docker-compose.yml`, starts the stack and reloads the dump.

The ldap uid/gid is read out of the target image rather than assumed: the
2.7.1 runtime image uses 102:103 where 2.6.13 used 101:102, and the Compose
entrypoint starts slapd with `-u ldap -g ldap`, so a wrong owner makes it exit
on the files it cannot read.

The HA stacks render their `cn=config` per node from a template that is never
kept on disk. There the script takes the dump, stops the stack and sets
`./data` aside - the part that has to happen while the old server is still
around - then prints the `setup-node.sh` and restore commands to finish with.
