# Migrating from `docker/` to the Helm chart

If you already run the sibling Docker Compose stack (`../../docker/`) and
want to move to Kubernetes, the path is: dump → tune values → install →
restore. The chart is a superset of the Docker setup, so every knob you
tuned in `docker-compose.yml` / `init-config/slapd-config.ldif` has an
equivalent value here.

## 0. Baseline - what you have

The Docker stack ships:
- OpenLDAP 2.6 with the same overlay stack (memberof, refint, ppolicy,
  dynlist, accesslog).
- phpLDAPadmin 2.x.
- Self Service Password 1.7.
- Optional TLS + backups + HAProxy for HA modes.

All three subcharts here match those apps 1-to-1, and the openldap
subchart bootstraps the same cn=config schema.

## 1. Take a fresh dump on the Docker side

```bash
cd docker/<mode>
openldap-cli backup data /tmp/data.ldif.gz
openldap-cli backup config /tmp/config.ldif.gz
```

For `standalone`, this is trivial. For `ha-active-active` /
`ha-active-passive`, dump from any node - they all carry the full tree.

Copy the dumps to somewhere the K8s cluster can pull from (an object
store, a git-crypt bundle, or `kubectl cp` later).

## 2. Translate values

Map from Docker to the chart:

| Docker knob | Chart value |
|-------------|-------------|
| `docker-compose.yml` `LDAP_BASE_DN` | `openldap.directory.suffix` |
| `docker-compose.yml` `LDAP_HOST` | Chart auto-derives from Service name (`<release>-openldap.<ns>.svc.cluster.local`) |
| `init-config/slapd-config.ldif` `olcDbMaxSize` | `openldap.database.main.maxSizeBytes` + `openldap.database.accesslog.maxSizeBytes` |
| `init-config/slapd-config.ldif` `olcAccessLogOps` | `openldap.accesslog.ops` |
| `init-config/slapd-config.ldif` `olcAccessLogSuccess` | `openldap.accesslog.logSuccess` |
| `init-config/slapd-config.ldif` `olcAccessLogPurge` | `openldap.accesslog.purge` |
| `init-config/slapd-config.ldif` `olcPPolicyDefault` | `openldap.ppolicy.defaultPolicyRDN` |
| `.env` (HA) `SERVER_ID` | `openldap.replication.serverIdBase` (per-pod ID computed from ordinal) |
| `.env` (HA) `NODE_URIS` (internal) | Auto - chart wires in-cluster peers via headless Service DNS |
| `.env` (HA) `NODE_URIS` (cross-DC entries) | `openldap.replication.externalPeers` |
| `.env` (HA) `REPLICATOR_DN` | `openldap.replication.replicator.dn` (default: `cn=replicator,ou=service-accounts`) |
| `certs.sh` `--cn` + `--san` | `openldap.tls.job.commonName` + `openldap.tls.job.subjectAltNames` |
| `certs.sh --renew-threshold-days` | `openldap.tls.job.renewThresholdDays` |
| `certs.sh` cron | `openldap.tls.job.schedule` |
| `base-ldifs/*.ldif` (custom entries) | Migrated via the LDIF restore in step 4 |
| Admin cronjob for backup | `openldap.backup.enabled: true` + `openldap.backup.schedule` |
| `ssp.conf.php` `$ldap_binddn` | `self-service-password.ldap.bind.dn` |
| `ssp.conf.php` `$keyphrase` | Auto-generated in `<release>-self-service-password-keyphrase` (or bring your own via `general.keyphraseExistingSecret`) |
| `ssp.conf.php` `$pwd_*` | `self-service-password.passwordPolicy.*` |
| `docker-compose.yml` phpldapadmin env | `phpldapadmin.ldap.*` + `phpldapadmin.app.*` |

## 3. Install the chart (empty tree)

Start with a values file that intentionally OMITS `openldap.users` /
`openldap.groups` - the restore will bring them, no need for the sync
Jobs to fight the import:

```bash
helm upgrade --install ldap kubernetes/charts/openldap-platform \
  --namespace ldap --create-namespace \
  -f migrated-values.yaml
```

Wait for the pods to be Ready.

## 4. Restore the dump

Follow [`backup-restore.md → Full DR`](./backup-restore.md#b-full-dr--restore-into-a-fresh-install).
In short:

```bash
kubectl -n ldap cp /tmp/data.ldif.gz \
  ldap-openldap-backup-<pod>:/backup/restore.ldif.gz

# Then a one-shot Job (see backup-restore.md) that runs:
openldap-cli backup restore /backup/restore.ldif.gz
```

Verify entry counts match the Docker source.

## 5. Move to declarative admin (optional)

Once the tree is restored, migrate ongoing admin from ad-hoc
`openldap-cli` calls to `values.yaml`. For each user in LDAP, add an
entry under `openldap.users`:

```yaml
openldap:
  users:
    - uid: alice
      givenName: Alice
      sn: Wonderland
      mail: alice@example.org
```

On the next `helm upgrade`, the sync Jobs `user info alice` → user
exists → run `user set` on the declared attributes (no destructive
change). Same for groups + policies.

**Watch out**: `onUserRemove: delete` (default) - any user present in
LDAP but NOT declared in `openldap.users` gets deleted. Two safe paths:
1. Declare every LDAP user in values.yaml BEFORE the first upgrade.
2. Temporarily set `onUserRemove: lock` while you catch up.

Also: chart-managed passwords are stored in per-user Secrets after the
sync Job runs. For users imported from the dump, no Secret exists -
they keep the password from the dump. To rotate, delete the user's
existing entry (or its userPassword) and let the sync Job re-create it
with a fresh password Secret.

## 6. Cut over clients

- Update client LDAP endpoints from the Docker host / HAProxy to the
  cluster's ingress hostname (or the in-cluster Service DNS if the
  client is another K8s workload).
- Re-issue trust bundle to clients if the CA changed
  (`tls.backend: job` regenerates one on install unless you piped in
  the Docker CA via `tls.backend: provided`).
- Retire the Docker stack.

## Docker → chart parity checklist

Confirm the following after cutover:

- [ ] Admin bind returns the same tree size + top-level structure.
- [ ] `openldap-cli` operations succeed against the K8s ingress.
- [ ] Prometheus exporter shows `openldap_up{...} == 1` on every pod.
- [ ] Replication peers (if HA) show `olcServerID` values as expected.
- [ ] SSP loads the change-password form and can change a real user's
      password.
- [ ] phpLDAPadmin login succeeds as an existing user.
- [ ] Nightly backup CronJob wrote today's dump to the backup PVC.
- [ ] Cert expiry visible via
      `openldap_tls_cert_not_after_timestamp_seconds` matches the
      migrated cert.
