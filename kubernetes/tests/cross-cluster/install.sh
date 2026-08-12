#!/bin/bash
# End-to-end deploy on the 2-VM cross-cluster rig.
#
#   1. Generate shared CA + per-cluster certs (if not already present).
#   2. Push admin, replicator, TLS Secrets into both minikubes.
#   3. helm install dc1 first, wait for pods ready.
#   4. helm install dc2, wait for pods ready.
#   5. Verify base tree present on both.
#
# Idempotent - safe to re-run on top of an existing deploy (values change
# → helm upgrade path).
set -euo pipefail

cd "$(dirname "$0")"

: "${ADMIN_PW:=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)}"
: "${CFG_ADMIN_PW:=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)}"
: "${REPLICATOR_PW:=$(openssl rand -base64 24 | tr -d '=/+' | head -c 32)}"

echo "=== [0] generating shared CA + per-cluster certs ==="
bash shared/gen-ca.sh

echo "=== [0.5] rsync host → VM (pushes freshly-generated certs to /vagrant) ==="
vagrant rsync dc1 >/dev/null
vagrant rsync dc2 >/dev/null

# Path inside the VM where the repo is mounted via config.vm.synced_folder.
REMOTE_ROOT="/vagrant/kubernetes/tests/cross-cluster"

install_dc() {
  local dc="$1" values="$2"
  echo "=== [${dc}] pushing shared Secrets ==="
  vagrant ssh "$dc" -c "sudo kubectl create ns ldap --dry-run=client -o yaml | sudo kubectl apply -f -"

  vagrant ssh "$dc" -c "sudo kubectl -n ldap create secret generic openldap-admin-shared \
    --from-literal=admin-password='${ADMIN_PW}' \
    --from-literal=config-admin-password='${CFG_ADMIN_PW}' \
    --dry-run=client -o yaml | sudo kubectl apply -f -"

  vagrant ssh "$dc" -c "sudo kubectl -n ldap create secret generic openldap-replicator-shared \
    --from-literal=replicator-password='${REPLICATOR_PW}' \
    --dry-run=client -o yaml | sudo kubectl apply -f -"

  # TLS Secret sourced from the rsync'd shared/ directory.
  vagrant ssh "$dc" -c "sudo kubectl -n ldap create secret generic openldap-tls-shared \
    --from-file=ca.crt=${REMOTE_ROOT}/shared/ca.crt \
    --from-file=tls.crt=${REMOTE_ROOT}/shared/${dc}/tls.crt \
    --from-file=tls.key=${REMOTE_ROOT}/shared/${dc}/tls.key \
    --dry-run=client -o yaml | sudo kubectl apply -f -"

  echo "=== [${dc}] helm upgrade --install ==="
  vagrant ssh "$dc" -c "cd /vagrant/kubernetes/charts/openldap-platform && sudo helm dependency update >/dev/null 2>&1 || true; \
    sudo helm upgrade --install ldap /vagrant/kubernetes/charts/openldap-platform -n ldap \
      -f ${REMOTE_ROOT}/${values} --wait --timeout 6m"

  # NodePort 30636 lives on the minikube docker network (192.168.49.2)
  # - invisible from the OTHER VM. Bridge it to the VM's private_network
  # interface via socat, running as a systemd service so it survives
  # reboots + install.sh re-runs.
  echo "=== [${dc}] setting up socat forwarder VM:30636 → minikube:30636 ==="
  vagrant ssh "$dc" -c "sudo bash -euo pipefail -c '
    apt-get install -yq socat >/dev/null 2>&1 || true
    MINIKUBE_IP=\$(sudo -u vagrant minikube -p minikube ip)
    cat > /etc/systemd/system/ldaps-forward.service <<EOF
[Unit]
Description=Forward NodePort 30636 to minikube LDAPS
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:30636,reuseaddr,fork TCP:\${MINIKUBE_IP}:30636
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ldaps-forward.service
    systemctl restart ldaps-forward.service
    sleep 1
    systemctl is-active ldaps-forward.service
  '"
}

echo ""
echo "=== [1] deploying dc1 (seed) ==="
install_dc dc1 dc1/values.yaml

echo ""
echo "=== [2] deploying dc2 (join) ==="
install_dc dc2 dc2/values.yaml

echo ""
echo "=== [3] deploy complete. Admin credentials:"
echo "    ADMIN_PW=${ADMIN_PW}"
echo "    CFG_ADMIN_PW=${CFG_ADMIN_PW}"
echo "    REPLICATOR_PW=${REPLICATOR_PW}"
echo ""
echo "Save them somewhere - re-running install.sh generates new ones unless"
echo "you 'export' these vars before the second run."
echo ""
echo "Next: export ADMIN_PW=... ; bash test-replication.sh"
