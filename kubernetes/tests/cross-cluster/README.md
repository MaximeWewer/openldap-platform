# Cross-cluster HA test rig (Vagrant + minikube)

Two Vagrant VMs (`dc1`, `dc2`), each running a single-node minikube, form
a synthetic mesh that mirrors what a real multi-DC deployment looks like:
distinct public IPs, distinct `serverIdBase`, TLS handshake over a shared
CA, LDAPS reached across a private network via NodePort.

Use this to:
- Validate `openldap.replication.externalPeers` end-to-end against real
  network traversal (as opposed to `helm template` alone).
- Reproduce a cross-cluster convergence issue reported in prod.
- Smoke-test chart changes that touch bootstrap / TLS / syncrepl before
  rolling anywhere real.

## Layout

```
kubernetes/tests/cross-cluster/
├── Vagrantfile              # 2 VMs, private_network on 192.168.59.0/24
├── provision.sh             # docker + kubectl + helm + minikube + openldap-cli + ldap-utils
├── shared/
│   ├── gen-ca.sh            # generates ca.crt/key + per-cluster server certs
│   ├── ca.crt|.key          # (gitignored) shared CA
│   ├── dc1/tls.{crt,key}    # (gitignored) dc1 server cert, SAN=192.168.59.20
│   └── dc2/tls.{crt,key}    # (gitignored) dc2 server cert, SAN=192.168.59.21
├── dc1/values.yaml          # serverIdBase=1,  seedOnOrdinalZeroOnly=true
├── dc2/values.yaml          # serverIdBase=10, seedOnOrdinalZeroOnly=false
├── install.sh               # gen CA, push Secrets, helm install dc1, then dc2
├── test-replication.sh      # write dc1 → read dc2, write dc2 → read dc1
└── cleanup.sh               # helm uninstall + wipe PVCs (keep minikube)
```

## Prerequisites

- Vagrant + VirtualBox (nested virt enabled on the host).
- **~12 GB free RAM** (default `VAGRANT_MEMORY=6144` × 2 VMs). Override
  with `VAGRANT_MEMORY=4096` if constrained; below 4 GB per VM minikube
  starts flapping.
- **~2 CPU cores per VM** (`VAGRANT_CPUS=2`, override if needed).
- Rsync (for `config.vm.synced_folder`).

## Run

```bash
cd kubernetes/tests/cross-cluster/

# 1. Boot both VMs - first run pulls the box + provisions minikube (~10 min).
vagrant up

# 2. Deploy: gen CA, push shared Secrets, helm install dc1 then dc2.
#    Prints the ADMIN_PW at the end - save it for step 3.
./install.sh
# ...
# === [3] deploy complete. Admin credentials:
#     ADMIN_PW=…
# ...

# 3. Verify cross-cluster replication both ways.
export ADMIN_PW=…      # copy the value printed by install.sh
./test-replication.sh

# 4. Reset the release (keep VMs + minikube for the next iteration).
./cleanup.sh

# 5. Nuke everything.
vagrant destroy -f
```

`install.sh` re-runs cleanly on top of an existing deploy - set every
password env var (`ADMIN_PW`, `CFG_ADMIN_PW`, `REPLICATOR_PW`) before the
second invocation to keep them stable, otherwise fresh randoms replace
what's in cluster.

## What the rig proves

- Boot order - dc1 seeds the base tree, dc2 joins empty and pulls the
  full tree via syncrepl (`seedOnOrdinalZeroOnly: false`).
- serverID disjoint - dc1 uses IDs 1-2, dc2 uses IDs 10-11; no
  olcServerID collision.
- Shared CA - the same `ca.crt` on both sides validates the peer's leaf
  cert on every syncrepl connection.
- Bi-directional writes - additions on either cluster converge on the
  other within `CONVERGE_WAIT` (default 15 s).
- NodePort exposure - LDAPS is reached across the Vagrant private
  network via `192.168.59.<other>:30636`, matching what a public LB
  would look like in prod.

## What the rig does NOT prove

- **Network policy enforcement** - minikube's default CNI (`bridge`)
  ignores `NetworkPolicy`. Both `dc1/values.yaml` and `dc2/values.yaml`
  set `networkPolicy.enabled: false` to reflect that. Test NP on a
  cluster with Calico / Cilium.
- **Ingress controllers** - the rig uses raw NodePort. Test SNI
  passthrough / Gateway API on a cluster where those actually run.
- **Backup / monitoring** - deliberately disabled in the test values
  to keep the rig lean. Enable them separately if you want to
  co-validate.

## Troubleshooting

**dc2 pod-0 stays in Init:CrashLoopBackOff** - usually a syncrepl
handshake failure. Check the bootstrap log
(`vagrant ssh dc2 -c "sudo kubectl -n ldap logs ldap-openldap-0 -c bootstrap"`)
then the ongoing slapd log
(`vagrant ssh dc2 -c "sudo kubectl -n ldap logs ldap-openldap-0 -c openldap"`).
Most common causes:
- Shared CA not pushed to dc2 → `install.sh` re-run
- `192.168.59.20:30636` unreachable from dc2 → `vagrant ssh dc2 -c "nc -zv 192.168.59.20 30636"`
- serverID collision → check both `values.yaml` set distinct `serverIdBase`.

**`nc -zv` from dc2 hits `Connection refused`** - dc1's minikube didn't
open the NodePort. `vagrant ssh dc1 -c "sudo kubectl -n ldap get svc ldap-openldap"`
should list `636:30636/TCP`. If missing, `install.sh` didn't complete on
dc1 - check its output.

**Everything works but writes on dc2 don't replicate back to dc1** -
`externalPeers` on dc1 doesn't include the dc2 endpoint. Verify by
re-reading `dc1/values.yaml` and re-running `install.sh`.
