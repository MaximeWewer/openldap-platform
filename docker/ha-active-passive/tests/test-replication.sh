#!/bin/bash
# Test HA replication: write on one node, verify all peers converge.
# Usage:
#   ./test-replication.sh                          # uses .env NODE_URIS
#   ./test-replication.sh ldap://host1 ldap://host2 ldap://host3
set -euo pipefail

cd "$(dirname "$0")"

if [ "$#" -gt 0 ]; then
  PEERS=("$@")
else
  [ -f .env ] || { echo "Error: .env missing"; exit 1; }
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  IFS=',' read -r -a PEERS <<< "$NODE_URIS"
fi

ADMIN_DN="cn=admin,dc=example,dc=org"
ADMIN_PW="adminpassword"
CONFIG_DN="cn=adminconfig,cn=config"
CONFIG_PW="${CONFIG_ADMIN_PASSWORD:-adminpasswordconfig}"
REPLICATE_CONFIG="${REPLICATE_CONFIG:-false}"
BASE_DN="dc=example,dc=org"
TEST_UID="repltest-$(date +%s)-$$"
TEST_DN="cn=$TEST_UID,ou=users,$BASE_DN"
WAIT_TIMEOUT=15
# cn=config converges slower than data: writing olcDatabase={1}mdb,cn=config
# makes slapd reload that database, which bounces the syncrepl sessions on
# every node. Measured at up to ~20s on a 3-node cluster.
CFG_WAIT_TIMEOUT=60

cleanup() {
  # Delete test entry on first node (replicates out)
  ldapdelete -x -H "${PEERS[0]}" -D "$ADMIN_DN" -w "$ADMIN_PW" "$TEST_DN" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Peers ==="
printf '  %s\n' "${PEERS[@]}"
echo

# === 1. Sanity check: each peer answers ===
echo "=== Sanity: namingContexts on each peer ==="
for uri in "${PEERS[@]}"; do
  printf "  %-40s " "$uri"
  if ldapsearch -x -H "$uri" -b "" -s base -LLL namingContexts 2>/dev/null | grep -q "$BASE_DN"; then
    echo "OK"
  else
    echo "FAIL"
    exit 1
  fi
done
echo

# === 2. Write on peer[0] ===
echo "=== Writing $TEST_DN on ${PEERS[0]} ==="
ldapadd -x -H "${PEERS[0]}" -D "$ADMIN_DN" -w "$ADMIN_PW" <<EOF
dn: $TEST_DN
objectClass: inetOrgPerson
cn: $TEST_UID
sn: $TEST_UID
uid: $TEST_UID
description: replication test entry
EOF

# === 3. Wait for convergence on each peer ===
echo
echo "=== Verifying replication on each peer (timeout ${WAIT_TIMEOUT}s) ==="
FAIL=0
for uri in "${PEERS[@]}"; do
  printf "  %-40s " "$uri"
  found=false
  for _ in $(seq 1 "$WAIT_TIMEOUT"); do
    if ldapsearch -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$TEST_DN" -s base -LLL dn 2>/dev/null | grep -q "^dn: $TEST_DN"; then
      found=true
      break
    fi
    sleep 1
  done
  if $found; then echo "REPLICATED"; else echo "MISSING"; FAIL=1; fi
done

echo
if [ "$FAIL" = "0" ]; then
  echo "=== Replication OK ==="
else
  echo "=== Replication FAILED on at least one peer ==="
  exit 1
fi

# === 4. Reverse direction (write on last peer, check others) ===
LAST_IDX=$((${#PEERS[@]} - 1))
if [ "$LAST_IDX" -gt 0 ]; then
  REV_UID="revtest-$(date +%s)-$$"
  REV_DN="cn=$REV_UID,ou=users,$BASE_DN"
  echo
  echo "=== Reverse: writing on ${PEERS[$LAST_IDX]} ==="
  if ldapadd -x -H "${PEERS[$LAST_IDX]}" -D "$ADMIN_DN" -w "$ADMIN_PW" <<EOF 2>&1
dn: $REV_DN
objectClass: inetOrgPerson
cn: $REV_UID
sn: $REV_UID
uid: $REV_UID
EOF
  then
    sleep 3
    printf "  Check on %s: " "${PEERS[0]}"
    if ldapsearch -x -H "${PEERS[0]}" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$REV_DN" -s base -LLL dn 2>/dev/null | grep -q "^dn:"; then
      echo "REPLICATED (active-active confirmed)"
    else
      echo "NOT REPLICATED (this peer is read-only, e.g. mirror-mode consumer)"
    fi
    ldapdelete -x -H "${PEERS[$LAST_IDX]}" -D "$ADMIN_DN" -w "$ADMIN_PW" "$REV_DN" 2>/dev/null || true
  else
    echo "  Write rejected on ${PEERS[$LAST_IDX]} (read-only consumer - expected in mirror mode)"
  fi
fi

# === 5. cn=config convergence (only when REPLICATE_CONFIG=true) ===
# Masters only: consumers (peer index >= 2) never consume cn=config by design.
# Writes a harmless olcLimits entry for a non-existent DN - no behavioural
# effect - and removes it on exit, so this is safe against a live cluster.
if [ "$REPLICATE_CONFIG" = "true" ] && [ "${#PEERS[@]}" -ge 2 ]; then
  MASTERS=("${PEERS[0]}" "${PEERS[1]}")
  MDB_DN="olcDatabase={1}mdb,cn=config"
  CFG_MARKER="cn=cfgtest-$(date +%s)-$$,$BASE_DN"
  CFG_LIMIT="dn.exact=\"$CFG_MARKER\" size=100"

  cfg_cleanup() {
    ldapmodify -x -H "${MASTERS[0]}" -D "$CONFIG_DN" -w "$CONFIG_PW" >/dev/null 2>&1 <<EOF || true
dn: $MDB_DN
delete: olcLimits
olcLimits: $CFG_LIMIT
EOF
  }
  trap 'cleanup; cfg_cleanup' EXIT

  echo
  echo "=== cn=config: writing olcLimits marker on ${MASTERS[0]} ==="
  ldapmodify -x -H "${MASTERS[0]}" -D "$CONFIG_DN" -w "$CONFIG_PW" <<EOF
dn: $MDB_DN
add: olcLimits
olcLimits: $CFG_LIMIT
EOF

  echo
  echo "=== Verifying cn=config replication on both masters (timeout ${CFG_WAIT_TIMEOUT}s) ==="
  CFG_FAIL=0
  for uri in "${MASTERS[@]}"; do
    printf "  %-40s " "$uri"
    found=false
    for _ in $(seq 1 "$CFG_WAIT_TIMEOUT"); do
      if ldapsearch -x -H "$uri" -D "$CONFIG_DN" -w "$CONFIG_PW" \
           -o ldif-wrap=no -b "$MDB_DN" -s base -LLL olcLimits 2>/dev/null | grep -q "$CFG_MARKER"; then
        found=true
        break
      fi
      sleep 1
    done
    if $found; then echo "REPLICATED"; else echo "MISSING"; CFG_FAIL=1; fi
  done

  if [ "${#PEERS[@]}" -gt 2 ]; then
    echo "  (consumers skipped - they never consume cn=config by design)"
  fi

  echo
  if [ "$CFG_FAIL" = "0" ]; then
    echo "=== cn=config replication OK ==="
  else
    echo "=== cn=config replication FAILED on at least one master ==="
    echo "    Check: syncprov must exist on olcDatabase={0}config, the peer's"
    echo "    olcSyncrepl must cover searchbase=olcDatabase={1}mdb,cn=config,"
    echo "    and CONFIG_ADMIN_PASSWORD must match on every node."
    exit 1
  fi
else
  echo
  echo "=== cn=config replication: skipped (REPLICATE_CONFIG != true) ==="
fi
