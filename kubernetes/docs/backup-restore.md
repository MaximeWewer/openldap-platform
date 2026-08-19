# Backup & restore

The chart takes two kinds of backup with `backup.enabled: true`:

- **Data dump** - `openldap-cli backup data /backup/data_<date>.ldif.gz`
  - every entry under the suffix, including operational attrs if
  `backup.includeOperational: true` (default).
- **Config dump** - `openldap-cli backup config /backup/config_<date>.ldif.gz`
  - every entry under `cn=config` (schemas, overlays, ACLs, DB defs).

Both are stored on the chart-managed PVC
`<release>-openldap-backup` (or `backup.persistence.existingClaim`),
pruned after `backup.retentionDays` (default 30).

## Fetching a backup off the cluster

```bash
NS=ldap
BACKUP_POD=$(kubectl -n $NS run backup-shell \
  --image=alpine:3.24 --restart=Never --rm -it \
  --overrides='{"spec":{"containers":[{"name":"t","image":"alpine:3.24",
    "command":["sh","-c","sleep 3600"],
    "volumeMounts":[{"name":"b","mountPath":"/backup"}]}],
    "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"ldap-openldap-backup"}}]}}' \
  -- true)

# List
kubectl -n $NS exec backup-shell -- ls -lh /backup

# Copy the latest data dump locally
kubectl -n $NS cp backup-shell:/backup/data_20260716.ldif.gz \
  ./data_20260716.ldif.gz
```

Simpler alternative - the same PVC can be mounted read-only in a debug
pod:

```bash
kubectl -n $NS debug --image=alpine:3.24 pod/ldap-openldap-0 \
  --target=openldap -- ls /var/lib/openldap
```

## Restore scenarios

### A. Rollback a specific user/group change

The sync Jobs are declarative - the cleanest way is to revert the
`openldap.users` / `openldap.groups` change in Git and let the next
`helm upgrade` reconcile. Deleted users can be re-created (with a fresh
password) or their DN + password restored from the dump:

```bash
# Extract the entry from the dump on a workstation
zgrep -A20 '^dn: cn=alice,ou=users,dc=example,dc=org' data_20260716.ldif.gz \
  > alice.ldif

# Push it back via the CLI (from a pod that already has openldap-cli):
kubectl -n $NS cp alice.ldif ldap-openldap-0:/tmp/
kubectl -n $NS exec ldap-openldap-0 -c openldap -- \
  ldapadd -x -H ldap://localhost:389 \
    -D cn=admin,dc=example,dc=org -w "$PW" -f /tmp/alice.ldif
```

### B. Full DR - restore into a fresh install

Assumes total loss (namespace wiped, all PVCs gone, but the backup PVC
survived, or the LDIF dumps are stored offsite).

1. **Reinstall the chart** with the same values (suffix, admin DN, ...)
   but WITHOUT any `users` / `groups` / `policies` - they'll be
   reconstituted from the dump, not from the sync Jobs.

   ```bash
   helm upgrade --install ldap kubernetes/charts/openldap-platform \
     -n ldap --create-namespace \
     -f my-values-no-sync.yaml
   ```

2. **Wait for pod-0 to be Ready.** The bootstrap creates an empty
   directory tree - the dc entry + OUs, no users.

3. **Restore the data dump.**

   Copy the dump into a pod:

   ```bash
   kubectl -n ldap cp data_20260716.ldif.gz \
     ldap-openldap-0:/tmp/restore.ldif.gz
   ```

   Run `backup restore` - the CLI handles gzipped input transparently:

   ```bash
   kubectl -n ldap exec ldap-openldap-0 -c openldap -- \
     sh -c 'cat > ~/.openldap-cli.yaml <<EOF
   default: prod
   profiles:
     prod:
       url: ldap://localhost:389
       base_dn: dc=example,dc=org
       bind_dn: cn=admin,dc=example,dc=org
       bind_pw: '"'"$(kubectl -n ldap get secret ldap-openldap-admin \
                       -o jsonpath='{.data.admin-password}' | base64 -d)"'"'
   EOF
   openldap-cli backup restore /tmp/restore.ldif.gz'
   ```

   > The pod's slapd container is distroless - no shell, no
   > openldap-cli. Do the restore from a temporary utility pod that
   > mounts the openldap image with a shell, or run the restore against
   > the LDAP Service from a sync-Job-like pod that already ships the
   > CLI.

   Simpler variant - a one-shot Job using the same image as the sync
   Jobs:

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata: { name: ldap-restore, namespace: ldap }
   spec:
     template:
       spec:
         restartPolicy: Never
         serviceAccountName: ldap-openldap-sync
         containers:
         - name: restore
           image: alpine:3.24
           command: [sh,-c]
           args:
           - |
             apk add --no-cache curl ca-certificates >/dev/null 2>&1
             curl -sL https://github.com/maximewewer/openldap-cli/releases/download/v2026.7.5/openldap-cli_v2026.7.5_linux_amd64.tar.gz \
               | tar xz -C /usr/local/bin openldap-cli
             chmod +x /usr/local/bin/openldap-cli
             export LDAP_URL=ldap://ldap-openldap.ldap.svc:389
             export LDAP_BASE_DN=dc=example,dc=org
             export LDAP_BIND_DN=cn=admin,dc=example,dc=org
             export LDAP_BIND_PW=$(cat /secrets/admin-password)
             openldap-cli backup restore /backup/restore.ldif.gz
           volumeMounts:
           - { name: sec, mountPath: /secrets }
           - { name: bak, mountPath: /backup }
         volumes:
         - name: sec
           secret: { secretName: ldap-openldap-admin }
         - name: bak
           persistentVolumeClaim: { claimName: ldap-openldap-backup }
   ```

4. **Wait for the restore Job to finish.** Then verify:

   ```bash
   kubectl -n ldap exec ldap-openldap-0 -- \
     ldapsearch -x -LLL -H ldap://localhost:389 \
       -D cn=admin,dc=example,dc=org -w "$PW" \
       -b dc=example,dc=org 'objectClass=*' dn | wc -l
   ```

5. **Optionally re-enable the sync Jobs** by putting your
   `openldap.users` / `openldap.groups` back in values and
   `helm upgrade`. They'll reconcile any drift on top of the restored
   tree.

### C. Restore cn=config (schema / overlays)

Rare - the chart's bootstrap already regenerates a working cn=config
from values.yaml. Restore config ONLY when:

- You modified cn=config out-of-band and want the old state back.
- You migrated to a chart version that changes the config seed and want
  the old seed for compatibility.

```bash
# Pod-0 stopped (statefulset scaled to 0), then:
kubectl -n ldap run cfg-restore \
  --image=alpine:3.24 --restart=Never \
  --overrides='...' \
  -- sh -c 'openldap-cli backup restore /backup/config_20260716.ldif.gz \
             --stop-on-error'
kubectl -n ldap scale statefulset ldap-openldap --replicas=1
```

Restoring cn=config on a running slapd is possible via the CLI but the
safer path is offline: scale to 0, run `slapadd -n 0` on a temporary
pod that mounts the same PVC, scale back up.

## HA-aware restore

Restore the data dump on ONE pod (usually ordinal 0) with syncrepl
temporarily paused (drop the pod from the Service selector via a label
hack, or scale peers to 0). Once the restore completes and pod-0 is
back in sync-provider mode, scale the peers back up - they pull the
restored tree via syncrepl.

The order matters:
1. Scale down peers (`kubectl scale statefulset ldap-openldap --replicas=1`).
2. Restore on pod-0.
3. Scale back up. Peers start empty and pull from pod-0.

Skipping step 1 causes the restore to fight ongoing syncrepl and
usually results in split-brain until purge cycles reconcile.

## Testing your DR

Run a DR drill quarterly:

1. Take a fresh backup.
2. Deploy a scratch namespace (`helm install ldap-dr ...`).
3. Restore the backup there.
4. Verify entry counts, sample bind, a few group memberships.
5. Delete the scratch namespace.

Automate steps 2-5 with a GitHub Action / cron pipeline pointing at a
throwaway K8s cluster.
