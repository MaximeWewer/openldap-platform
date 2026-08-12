#!/bin/bash
# Verify cross-cluster replication works both ways.
#   1. Base tree present on both DCs (dc1 seeded, dc2 pulled it).
#   2. Write on dc1 pod-0 → appears on dc2 within N seconds.
#   3. Write on dc2 pod-0 → appears on dc1 within N seconds.
#
# Requires install.sh to have been run first and $ADMIN_PW to be set
# (or set it below to whatever install.sh printed).
set -euo pipefail

cd "$(dirname "$0")"

: "${ADMIN_PW:?export ADMIN_PW to the value install.sh printed}"
: "${CONVERGE_WAIT:=15}"

DC1_HOST="192.168.59.20"
DC2_HOST="192.168.59.21"

ldap_search_via() {
  # $1 = VM name (dc1/dc2), $2 = search base, $3 = filter, ...
  local vm="$1"; shift
  vagrant ssh "$vm" -c "LDAPTLS_REQCERT=allow ldapsearch -x -LLL \
    -H ldaps://localhost:30636 \
    -D 'cn=admin,dc=example,dc=org' -w '${ADMIN_PW}' \
    $*"
}

ldap_add_via() {
  local vm="$1" ldif="$2"
  echo "$ldif" | vagrant ssh "$vm" -c "cat > /tmp/entry.ldif && LDAPTLS_REQCERT=allow ldapadd -x \
    -H ldaps://localhost:30636 \
    -D 'cn=admin,dc=example,dc=org' -w '${ADMIN_PW}' \
    -f /tmp/entry.ldif && rm /tmp/entry.ldif"
}

echo "=== [1] base tree present on both DCs ==="
for dc in dc1 dc2; do
  echo "--- $dc ---"
  ldap_search_via "$dc" "-b dc=example,dc=org dn" | head -12
done

echo ""
echo "=== [2] WRITE cross-cluster-1 on dc1, wait ${CONVERGE_WAIT}s, read from dc2 ==="
ldap_add_via dc1 "dn: cn=cross-cluster-1,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
cn: cross-cluster-1
sn: fromDC1
uid: cc1
userPassword: cc1pw"
sleep "$CONVERGE_WAIT"
if ldap_search_via dc2 "-b 'cn=cross-cluster-1,ou=users,dc=example,dc=org' dn" | grep -q "cn=cross-cluster-1"; then
  echo "PASS - cross-cluster-1 replicated dc1 → dc2"
else
  echo "FAIL - cross-cluster-1 not on dc2 after ${CONVERGE_WAIT}s"
  exit 1
fi

echo ""
echo "=== [3] WRITE cross-cluster-2 on dc2, wait ${CONVERGE_WAIT}s, read from dc1 ==="
ldap_add_via dc2 "dn: cn=cross-cluster-2,ou=users,dc=example,dc=org
objectClass: inetOrgPerson
cn: cross-cluster-2
sn: fromDC2
uid: cc2
userPassword: cc2pw"
sleep "$CONVERGE_WAIT"
if ldap_search_via dc1 "-b 'cn=cross-cluster-2,ou=users,dc=example,dc=org' dn" | grep -q "cn=cross-cluster-2"; then
  echo "PASS - cross-cluster-2 replicated dc2 → dc1"
else
  echo "FAIL - cross-cluster-2 not on dc1 after ${CONVERGE_WAIT}s"
  exit 1
fi

echo ""
echo "=== all cross-cluster replication tests passed ==="
