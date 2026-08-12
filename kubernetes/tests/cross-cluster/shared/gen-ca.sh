#!/bin/bash
# Generate a single shared CA + one server cert per cluster. Every peer
# in the mesh trusts the same CA, so cross-cluster syncrepl handshakes
# validate cleanly.
#
# Outputs (in this directory):
#   ca.crt / ca.key       shared CA
#   dc1/tls.crt+key       server cert with SAN=192.168.59.20,dc1
#   dc2/tls.crt+key       server cert with SAN=192.168.59.21,dc2
set -euo pipefail

cd "$(dirname "$0")"

DC1_IP="${DC1_IP:-192.168.59.20}"
DC2_IP="${DC2_IP:-192.168.59.21}"
CA_DAYS="${CA_DAYS:-3650}"
CERT_DAYS="${CERT_DAYS:-365}"

if [ -f ca.crt ] && [ -f ca.key ]; then
  echo "=== CA already present - skipping (rm ca.{crt,key} to regenerate) ==="
else
  echo "=== generating CA (${CA_DAYS}d) ==="
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days "${CA_DAYS}" \
    -out ca.crt -subj "/CN=openldap-crosscluster-ca"
fi

gen_cert() {
  local name="$1" ip="$2"
  mkdir -p "$name"
  echo "=== generating cert for ${name} (SAN: DNS:${name},IP:${ip},DNS:*.${name}) ==="
  openssl genrsa -out "${name}/tls.key" 2048
  openssl req -new -key "${name}/tls.key" -out "${name}/tls.csr" \
    -subj "/CN=${name}"
  openssl x509 -req -in "${name}/tls.csr" \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${name}/tls.crt" -days "${CERT_DAYS}" -sha256 \
    -extfile <(printf "subjectAltName=DNS:%s,DNS:*.%s,IP:%s,DNS:ldap-openldap-headless.ldap.svc.cluster.local,DNS:ldap-openldap-0.ldap-openldap-headless.ldap.svc.cluster.local,DNS:ldap-openldap-1.ldap-openldap-headless.ldap.svc.cluster.local,DNS:ldap-openldap-2.ldap-openldap-headless.ldap.svc.cluster.local,DNS:ldap-openldap.ldap.svc.cluster.local" "$name" "$name" "$ip")
  rm -f "${name}/tls.csr"
}

gen_cert dc1 "$DC1_IP"
gen_cert dc2 "$DC2_IP"

echo "=== done. CA + per-cluster server certs ready under $(pwd) ==="
