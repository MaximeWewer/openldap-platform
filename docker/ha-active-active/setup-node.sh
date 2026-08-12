#!/bin/bash
# Per-node bootstrap for ACTIVE-ACTIVE (N-way Multi-Master).
# Every node is a master; writes accepted on all peers; delta-syncrepl mesh.
#
# Usage: ./setup-node.sh [--reset]
set -euo pipefail

cd "$(dirname "$0")"

# === Load env ===
if [ ! -f .env ]; then
  echo "Error: .env missing. Copy .env.example and edit." >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

: "${SERVER_ID:?SERVER_ID required}"
: "${NODE_URIS:?NODE_URIS required}"
: "${REPLICATOR_DN:?REPLICATOR_DN required}"
: "${REPLICATOR_PASSWORD:?REPLICATOR_PASSWORD required}"
: "${HAPROXY_STATS_USER:=admin}"
: "${HAPROXY_STATS_PASSWORD:=admin}"
: "${REPLICATE_CONFIG:=false}"
: "${CONFIG_ADMIN_PASSWORD:=adminpasswordconfig}"

IMAGE="cleanstart/openldap:2.6.13"
LDAP_UID=101
LDAP_GID=102

IFS=',' read -r -a PEERS <<< "$NODE_URIS"
NUM_PEERS=${#PEERS[@]}

if [ "$SERVER_ID" -lt 1 ] || [ "$SERVER_ID" -gt "$NUM_PEERS" ]; then
  echo "Error: SERVER_ID=$SERVER_ID out of range (1..$NUM_PEERS)" >&2
  exit 1
fi

echo "=== Active-Active node config ==="
echo "  ServerID:   $SERVER_ID / $NUM_PEERS"
echo "  Peers:      $NODE_URIS"
echo "  cn=config replication: $REPLICATE_CONFIG"

# === Reset check ===
SLAPD_DIR="./data/slapd.d"
if [ -d "$SLAPD_DIR" ] && [ "$(ls -A $SLAPD_DIR 2>/dev/null)" ]; then
  if [ "${1:-}" = "--reset" ]; then
    echo "Resetting state..."
    docker compose --profile ui down 2>/dev/null || true
    docker run --rm -v "$(pwd)/data:/data" alpine:latest sh -c "rm -rf /data/slapd.d/* /data/openldap-data/* /data/accesslog-data/*"
  else
    echo "Error: $SLAPD_DIR already populated. Run with --reset to wipe." >&2
    exit 1
  fi
fi

mkdir -p ./data/slapd.d ./data/openldap-data ./data/accesslog-data

# === Hash replicator password ===
echo "=== Hashing replicator password ==="
REPLICATOR_PASSWORD_HASH=$(docker run --rm --entrypoint slappasswd "$IMAGE" -s "$REPLICATOR_PASSWORD")

# === Hash cn=config rootDN password ===
# Rendered (instead of hardcoded in the template) because the cn=config
# syncrepl consumer has to bind with the CLEARTEXT value: the rootDN bind
# bypasses the {0}config ACL, so no extra ACL clause is needed.
CONFIG_ROOTPW_HASH=$(docker run --rm --entrypoint slappasswd "$IMAGE" -s "$CONFIG_ADMIN_PASSWORD")

# === serverID ===
# With cn=config replication the whole config DB is copied, `cn=config` root
# entry included, so a single-int olcServerID would be overwritten by whichever
# peer wrote last. slapd's answer is the URL form: the SAME list on every node,
# each node recognising its own line by matching the URL against one of its
# listeners.
# The URLs are the REAL peer addresses from NODE_URIS. That match is what also
# makes slapd DROP the syncrepl entry pointing at itself - without it a node
# consumes its own config and syncprov answers its own consumer thread with
# `(53) Server is unwilling to perform`, stalling the real consumers.
# Binding a docker-host address requires host networking, which the generated
# compose override switches on for exactly this case.
SELF_URI="${PEERS[$((SERVER_ID - 1))]}"
if [ "$REPLICATE_CONFIG" = "true" ]; then
  SERVER_IDS_BLOCK=""
  IDX=0
  for uri in "${PEERS[@]}"; do
    IDX=$((IDX + 1))
    SERVER_IDS_BLOCK+="olcServerID: $IDX $uri"$'\n'
  done
  SERVER_IDS_BLOCK="${SERVER_IDS_BLOCK%$'\n'}"
else
  SERVER_IDS_BLOCK="olcServerID: $SERVER_ID"
fi

# === Build syncrepl block: every node replicates from every peer (incl. self, filtered by serverID) ===
build_syncrepl_entry() {
  local rid="$1" provider="$2"
  printf 'olcSyncRepl: rid=%03d provider=%s\n' "$rid" "$provider"
  printf '  bindmethod=simple binddn="%s"\n' "$REPLICATOR_DN"
  printf '  credentials="%s"\n' "$REPLICATOR_PASSWORD"
  printf '  searchbase="dc=example,dc=org"\n'
  printf '  type=refreshAndPersist retry="5 60 60 +"\n'
  printf '  timeout=1 schemachecking=on\n'
  printf '  logbase="cn=accesslog"\n'
  printf '  logfilter="(&(objectClass=auditWriteObject)(reqResult=0))"\n'
  printf '  syncdata=accesslog\n'
}

MDB_SYNCREPL_BLOCK=""
IDX=0
for uri in "${PEERS[@]}"; do
  IDX=$((IDX + 1))
  MDB_SYNCREPL_BLOCK+="$(build_syncrepl_entry "$IDX" "$uri")"$'\n'
done
MDB_SYNCREPL_BLOCK="${MDB_SYNCREPL_BLOCK%$'\n'}"
MDB_MIRRORMODE_LINE="olcMirrorMode: TRUE"

# === cn=config replication (optional) ===
# ONE syncrepl per peer over the WHOLE cn=config. Not several partial ones with
# narrower searchbases: syncrepl entries on the same database share a single
# contextCSN, so one advancing it makes the others believe they are current and
# silently skip changes - the consumer then reports an up-to-date contextCSN
# while its entries are stale. Measured, not theorised.
# Self IS listed: the list must be identical on every node (it replicates too),
# and slapd drops the self entry at runtime via the olcServerID URL match.
# Not delta-syncrepl: the accesslog overlay is attached to {1}mdb only, so the
# config DB has no changelog to pull from.
# binddn is the config rootDN - it bypasses the {0}config ACL, which otherwise
# denies everyone but itself (`by * none`).
build_config_syncrepl_entry() {
  local rid="$1" provider="$2"
  printf 'olcSyncRepl: rid=%03d provider=%s\n' "$rid" "$provider"
  printf '  bindmethod=simple binddn="cn=adminconfig,cn=config"\n'
  printf '  credentials="%s"\n' "$CONFIG_ADMIN_PASSWORD"
  printf '  searchbase="cn=config"\n'
  printf '  type=refreshAndPersist retry="5 60 60 +"\n'
  printf '  timeout=1\n'
}

CONFIG_SYNCREPL_BLOCK=""
CONFIG_MIRRORMODE_LINE=""
CONFIG_SYNCPROV_BLOCK=""
if [ "$REPLICATE_CONFIG" = "true" ]; then
  IDX=0
  for uri in "${PEERS[@]}"; do
    IDX=$((IDX + 1))
    # rid namespace 1xx keeps config rids clear of the mdb rids above.
    CONFIG_SYNCREPL_BLOCK+="$(build_config_syncrepl_entry "$((100 + IDX))" "$uri")"$'\n'
  done
  CONFIG_SYNCREPL_BLOCK="${CONFIG_SYNCREPL_BLOCK%$'\n'}"
  CONFIG_MIRRORMODE_LINE="olcMirrorMode: TRUE"
  # syncprov on {0}config - without a provider overlay the config DB serves no
  # sync context and every consumer stalls.
  # Leading + trailing newline keep the entry blank-line separated.
  CONFIG_SYNCPROV_BLOCK=$'\ndn: olcOverlay=syncprov,olcDatabase={0}config,cn=config\nobjectClass: olcOverlayConfig\nobjectClass: olcSyncProvConfig\nolcOverlay: syncprov\nolcSpCheckpoint: 100 10\nolcSpSessionLog: 100\n'
fi

# === Render slapd-config.ldif ===
echo "=== Rendering slapd-config.ldif ==="
TMP_CFG=$(mktemp)
TMP_DATA=$(mktemp -d)
cleanup() { rm -f "$TMP_CFG"; rm -rf "$TMP_DATA"; }
trap cleanup EXIT

export SERVER_IDS_BLOCK MDB_SYNCREPL_BLOCK MDB_MIRRORMODE_LINE REPLICATOR_DN
export CONFIG_SYNCREPL_BLOCK CONFIG_MIRRORMODE_LINE CONFIG_SYNCPROV_BLOCK CONFIG_ROOTPW_HASH
python3 - > "$TMP_CFG" <<'PYEOF'
import os
with open("init-config/slapd-config.ldif.tmpl") as f:
    tpl = f.read()
tpl = tpl.replace("@@SERVER_IDS@@",        os.environ.get("SERVER_IDS_BLOCK", ""))
tpl = tpl.replace("@@MDB_SYNCREPL@@",      os.environ.get("MDB_SYNCREPL_BLOCK", ""))
tpl = tpl.replace("@@MDB_MIRRORMODE@@",    os.environ.get("MDB_MIRRORMODE_LINE", ""))
tpl = tpl.replace("@@CONFIG_SYNCREPL@@",   os.environ.get("CONFIG_SYNCREPL_BLOCK", ""))
tpl = tpl.replace("@@CONFIG_MIRRORMODE@@", os.environ.get("CONFIG_MIRRORMODE_LINE", ""))
tpl = tpl.replace("@@CONFIG_SYNCPROV@@",   os.environ.get("CONFIG_SYNCPROV_BLOCK", ""))
tpl = tpl.replace("@@CONFIG_ROOTPW@@",     os.environ["CONFIG_ROOTPW_HASH"])
tpl = tpl.replace("@@REPLICATOR_DN@@",     os.environ["REPLICATOR_DN"])
print(tpl)
PYEOF

# === Bootstrap cn=config ===
echo "=== Bootstrapping cn=config ==="
docker run --rm --user root \
  -v "$(pwd)/data/slapd.d:/etc/openldap/slapd.d" \
  -v "$(pwd)/data/openldap-data:/var/lib/openldap/openldap-data" \
  -v "$(pwd)/data/accesslog-data:/var/lib/openldap/accesslog-data" \
  -v "$TMP_CFG:/init/slapd-config.ldif:ro" \
  --entrypoint slapadd "$IMAGE" \
  -n 0 -F /etc/openldap/slapd.d -l /init/slapd-config.ldif

# === Load initial data (SERVER_ID=1 only - peers sync from it) ===
if [ "$SERVER_ID" = "1" ]; then
  echo "=== Loading base data (node 1 - peers will sync from here) ==="
  awk -v h="$REPLICATOR_PASSWORD_HASH" '
    /^userPassword:/ { print "userPassword: " h; next }
    { print }
  ' ./init-ldifs/replicator.ldif > "$TMP_DATA/replicator-hashed.ldif"

  {
    for ldif in \
      ../base-ldifs/01-base.ldif \
      ../base-ldifs/02-org-ou.ldif \
      ../base-ldifs/03-users.ldif \
      ../base-ldifs/04-service-accounts.ldif \
      ../base-ldifs/05-groups.ldif \
      ../base-ldifs/06-default-ppolicy.ldif \
      "$TMP_DATA/replicator-hashed.ldif"; do
      sed 's/\r$//' "$ldif"
      echo ""; echo ""
    done
  } > "$TMP_DATA/all-data.ldif"

  docker run --rm --user root \
    -v "$(pwd)/data/slapd.d:/etc/openldap/slapd.d" \
    -v "$(pwd)/data/openldap-data:/var/lib/openldap/openldap-data" \
    -v "$(pwd)/data/accesslog-data:/var/lib/openldap/accesslog-data" \
    -v "$TMP_DATA:/init-data:ro" \
    --entrypoint slapadd "$IMAGE" \
    -n 1 -F /etc/openldap/slapd.d -l /init-data/all-data.ldif
else
  echo "=== SERVER_ID=$SERVER_ID: skipping data load (will sync from peers) ==="
fi

# === Fix permissions ===
echo "=== Fixing permissions ==="
docker run --rm --user root \
  -v "$(pwd)/data/slapd.d:/etc/openldap/slapd.d" \
  -v "$(pwd)/data/openldap-data:/var/lib/openldap/openldap-data" \
  -v "$(pwd)/data/accesslog-data:/var/lib/openldap/accesslog-data" \
  alpine:latest sh -c "chown -R ${LDAP_UID}:${LDAP_GID} /etc/openldap/slapd.d /var/lib/openldap/openldap-data /var/lib/openldap/accesslog-data"

# === Render haproxy.cfg ===
echo "=== Rendering haproxy.cfg (roundrobin LB) ==="
LDAP_SERVERS=""; LDAPS_SERVERS=""; IDX=0
for uri in "${PEERS[@]}"; do
  IDX=$((IDX + 1))
  HOSTPORT="${uri#ldap://}"
  HOST="${HOSTPORT%:*}"
  LDAP_SERVERS+="    server node${IDX} ${HOST}:389 check inter 5s rise 2 fall 3"$'\n'
  LDAPS_SERVERS+="    server node${IDX}_s ${HOST}:636 check inter 5s rise 2 fall 3"$'\n'
done
LDAP_SERVERS="${LDAP_SERVERS%$'\n'}"
LDAPS_SERVERS="${LDAPS_SERVERS%$'\n'}"

export LDAP_SERVERS LDAPS_SERVERS HAPROXY_STATS_USER HAPROXY_STATS_PASSWORD
python3 - > haproxy/haproxy.cfg <<'PYEOF'
import os
with open("haproxy/haproxy.cfg.tmpl") as f: tpl=f.read()
for k in ("HAPROXY_STATS_USER","HAPROXY_STATS_PASSWORD","LDAP_SERVERS","LDAPS_SERVERS"):
    tpl=tpl.replace(f"@@{k}@@", os.environ.get(k,""))
print(tpl)
PYEOF

# === compose override (cn=config replication only) ===
# Two things are needed and they are linked:
#   * slapd must LISTEN on the exact URL carried in olcServerID, otherwise it
#     refuses to start ("no serverID / URL match found") and never filters the
#     syncrepl entry pointing at itself;
#   * that URL is the docker HOST address, which a bridge-networked container
#     cannot bind - hence network_mode: host.
# `networks` and `ports` are reset because compose rejects them alongside
# network_mode: host (compose >= 2.24 / spec `!reset`).
# entrypoint, NOT command: the image ENTRYPOINT is already a full slapd argv,
# so a command: would be APPENDED and slapd would abort on the extra argument.
OVERRIDE_FILE="docker-compose.override.yml"
if [ "$REPLICATE_CONFIG" = "true" ]; then
  echo "=== Rendering $OVERRIDE_FILE (host networking + pinned listeners) ==="
  SELF_HOSTPORT="${SELF_URI#ldap://}"
  SELF_HOST="${SELF_HOSTPORT%:*}"
  LISTEN_URIS="$SELF_URI ldap://127.0.0.1:389 ldaps://${SELF_HOST}:636 ldaps://127.0.0.1:636"
  cat > "$OVERRIDE_FILE" <<EOF
# GENERATED by setup-node.sh - do not edit (regenerated on every run).
# Present only because REPLICATE_CONFIG=true.
services:
  openldap:
    network_mode: host
    networks: !reset null
    ports: !reset []
    # Older Docker Engines reject `hostname` combined with network_mode: host
    # ("conflicting options: hostname and the network mode"). Under host
    # networking the container uses the host's name anyway, so drop it.
    hostname: !reset null
    entrypoint: ["slapd", "-u", "ldap", "-g", "ldap", "-h", "$LISTEN_URIS", "-d", "64"]
EOF
else
  rm -f "$OVERRIDE_FILE"
fi

# === Start containers ===
echo "=== Starting containers ==="
PROFILES=()
if [ "${ENABLE_PHPLDAPADMIN:-false}" = "true" ]; then
  PROFILES=(--profile ui)
fi
docker compose "${PROFILES[@]}" up -d

echo ""
echo "=== Waiting for OpenLDAP ==="
for i in $(seq 1 30); do
  if docker exec openldap ldapsearch -x -H ldap://localhost:389 -b "" -s base "(objectClass=*)" namingContexts >/dev/null 2>&1; then
    echo "OpenLDAP ready on node $SERVER_ID."
    break
  fi
  [ "$i" -eq 30 ] && { echo "OpenLDAP did not start in time"; docker logs openldap | tail -30; exit 1; }
  sleep 1
done

echo ""
echo "Node $SERVER_ID up (active-active master)."
echo "  Direct LDAP:     ldap://<node-ip>:389"
echo "  HAProxy LDAP LB: ldap://<node-ip>:1389  (roundrobin)"
echo "  HAProxy stats:   http://<node-ip>:8404  ($HAPROXY_STATS_USER/$HAPROXY_STATS_PASSWORD)"
