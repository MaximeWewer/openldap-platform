#!/bin/bash
# Provision a Vagrant VM with docker + kubectl + helm + minikube, then start
# a single-node minikube cluster. Idempotent - safe to re-run via `vagrant
# provision`.
set -euo pipefail

echo "=== [${NODE_NAME:-?}] wait for cloud-init to settle ==="
cloud-init status --wait || true

echo "=== apt: install prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true

apt-get -o DPkg::Lock::Timeout=600 update -yq
apt-get -o DPkg::Lock::Timeout=600 install -yq \
  ca-certificates curl gnupg lsb-release conntrack socat jq

# ---------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=600 update -yq
  apt-get -o DPkg::Lock::Timeout=600 install -yq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker vagrant
fi
systemctl enable --now docker

# ---------------------------------------------------------------------------
# kubectl (pinned to match minikube's default target)
# ---------------------------------------------------------------------------
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.31.0}"
if ! command -v kubectl >/dev/null 2>&1 || \
   ! kubectl version --client 2>/dev/null | grep -q "$KUBECTL_VERSION"; then
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

# ---------------------------------------------------------------------------
# helm
# ---------------------------------------------------------------------------
HELM_VERSION="${HELM_VERSION:-v3.15.4}"
if ! command -v helm >/dev/null 2>&1 || \
   ! helm version --short 2>/dev/null | grep -q "$HELM_VERSION"; then
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | \
    tar xz --strip-components=1 -C /usr/local/bin linux-amd64/helm
  chmod +x /usr/local/bin/helm
fi

# ---------------------------------------------------------------------------
# minikube
# ---------------------------------------------------------------------------
MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.34.0}"
if ! command -v minikube >/dev/null 2>&1 || \
   ! minikube version | grep -q "$MINIKUBE_VERSION"; then
  curl -fsSL "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64" \
    -o /usr/local/bin/minikube
  chmod +x /usr/local/bin/minikube
fi

# ---------------------------------------------------------------------------
# openldap-cli - used by the test scripts to bind/search from the host.
# ---------------------------------------------------------------------------
CLI_VERSION="${CLI_VERSION:-v2026.7.2}"
if ! command -v openldap-cli >/dev/null 2>&1 || \
   ! openldap-cli version 2>/dev/null | grep -q "$CLI_VERSION"; then
  curl -fsSL "https://github.com/maximewewer/openldap-cli/releases/download/${CLI_VERSION}/openldap-cli_${CLI_VERSION}_linux_amd64.tar.gz" | \
    tar xz -C /usr/local/bin openldap-cli
  chmod +x /usr/local/bin/openldap-cli
fi

# ---------------------------------------------------------------------------
# ldap-utils - for ldapsearch/ldapadd probes.
# ---------------------------------------------------------------------------
apt-get -o DPkg::Lock::Timeout=600 install -yq ldap-utils

# ---------------------------------------------------------------------------
# minikube - start (as vagrant user, docker driver).
# The `apiserver-ips` extra IP is critical: without it the apiserver's
# TLS cert doesn't cover the VM's private_network address and kubectl
# from the OTHER VM (or the host) can't reach it. We don't need
# cross-cluster kubectl access here, but keep the flag for future use.
# ---------------------------------------------------------------------------
# Compute resources OUTSIDE the heredoc - dodges locale-sensitive parsing
# of `free -m`. /proc/meminfo is always English + numeric.
CPU_COUNT="$(nproc)"
MEM_MB="$(awk '/^MemTotal:/{print int($2/1024) - 1024}' /proc/meminfo)"

sudo -u vagrant -H \
  KUBECTL_VERSION="${KUBECTL_VERSION}" \
  NODE_IP="${NODE_IP}" \
  CPU_COUNT="${CPU_COUNT}" \
  MEM_MB="${MEM_MB}" \
  bash -euo pipefail <<'EOF'
export MINIKUBE_HOME=/home/vagrant/.minikube
if ! minikube status -p minikube >/dev/null 2>&1; then
  echo "=== starting minikube (cpus=${CPU_COUNT} mem=${MEM_MB}Mi) ==="
  minikube start --driver=docker \
    --cpus="${CPU_COUNT}" --memory="${MEM_MB}" \
    --kubernetes-version="${KUBECTL_VERSION}" \
    --apiserver-ips="${NODE_IP}"
else
  echo '=== minikube already running ==='
fi
minikube kubectl -- version --client=true >/dev/null
EOF

# root also gets a kubeconfig for easy `kubectl` in provisioned scripts.
mkdir -p /root/.kube
cp /home/vagrant/.kube/config /root/.kube/config

echo "=== [${NODE_NAME:-?}] ready - apiserver on \$(minikube -p minikube ip) ==="
