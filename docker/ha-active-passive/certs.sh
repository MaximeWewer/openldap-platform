#!/bin/bash
# Generate / renew the local CA + OpenLDAP server certificate (ECDSA P-384).
#
# Renewal policy:
#   --force                       : regen LDAP cert unconditionally
#   --renew-threshold-days N      : regen LDAP cert if expires within N days (default: 30)
#   --regen-ca                    : regen the CA too (rare - invalidates server cert)
#
# Multi-node (HA): the CA must be SHARED across all peers so clients only trust one CA
# and HAProxy failover doesn't cause cert mismatch. Workflow:
#   1. On the CA master (e.g. node 1): run certs.sh once - it creates the CA + own cert.
#   2. Copy openldapCA.crt + openldapCA.key to each peer's certs/ (manual scp or
#      tests/distribute-ca.sh for the Vagrant cluster).
#   3. On each peer: run certs.sh - it detects the existing CA and ONLY generates a
#      per-node server cert (signed by that CA), with the per-node SAN you pass.
#   --ca-from PATH                : copy openldapCA.crt + openldapCA.key from PATH into
#                                   local certs/ before generating (PATH is a local dir).
#
# Container handling:
#   --restart                     : if cert was renewed, restart the openldap container
#   slapd reads TLS material at startup, so a restart is required to pick up new files.
#   HAProxy in HA modes is TCP passthrough (no TLS termination) - no restart needed.
#
# Output:
#   --quiet                       : suppress non-action output (good for cron MAILTO)
#
# Cron example (weekly check, auto-restart if renewed):
#   0 4 * * 1 cd /path/to/<mode> && bash certs.sh --restart --quiet
set -euo pipefail

# === Defaults ===
CERT_DIR="$PWD/certs"
FORCE_LDAP="no"
REGEN_CA="no"
RESTART_CONTAINER="no"
QUIET="no"
RENEW_THRESHOLD_DAYS=30
CN="openldap.local"
SAN="DNS:openldap.local,DNS:openldap,IP:127.0.0.1"
CA_DAYS=1095     # 3 years
LDAP_DAYS=365    # 1 year
CONTAINER_NAME="openldap"
CA_FROM=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --force                        regen LDAP cert unconditionally
  --renew-threshold-days N       regen LDAP cert if expires within N days (default: $RENEW_THRESHOLD_DAYS)
  --regen-ca                     regen the CA too (rare - invalidates server cert)
  --restart                      restart the openldap container if a cert was renewed
  --quiet                        suppress non-action output (good for cron)
  --cn NAME                      Common Name for LDAP cert (default: $CN)
  --san LIST                     subjectAltName list (default: $SAN)
  --container-name NAME          docker container to restart (default: $CONTAINER_NAME)
  --ca-from PATH                 copy openldapCA.crt+.key from PATH into certs/ before generating
                                 (use to share the CA across HA peers)
  -h, --help                     show this help
EOF
  exit "${1:-0}"
}

# === Parse CLI ===
while [[ $# -gt 0 ]]; do
  case $1 in
    --force)                  FORCE_LDAP="yes"; shift ;;
    --regen-ca)               REGEN_CA="yes"; shift ;;
    --restart)                RESTART_CONTAINER="yes"; shift ;;
    --quiet)                  QUIET="yes"; shift ;;
    --renew-threshold-days)   RENEW_THRESHOLD_DAYS="$2"; shift 2 ;;
    --cn)                     CN="$2"; shift 2 ;;
    --san)                    SAN="$2"; shift 2 ;;
    --container-name)         CONTAINER_NAME="$2"; shift 2 ;;
    --ca-from)                CA_FROM="$2"; shift 2 ;;
    -h|--help)                usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

log() { [ "$QUIET" = "yes" ] || echo "$@"; }
action() { echo "$@"; }   # always printed (renewal/error events)

CA_KEY_PATH="$CERT_DIR/openldapCA.key"
CA_CERT_PATH="$CERT_DIR/openldapCA.crt"
LDAP_KEY_PATH="$CERT_DIR/openldap.key"
LDAP_CRT_PATH="$CERT_DIR/openldap.crt"
CSR_PATH="$CERT_DIR/openldap.csr"
OPENSSL_CNF="$CERT_DIR/openssl.cnf"

mkdir -p "$CERT_DIR"
RENEWED="no"

# === Optionally seed the CA from another location (HA peer setup) ===
if [[ -n "$CA_FROM" ]]; then
  if [[ ! -f "$CA_FROM/openldapCA.crt" || ! -f "$CA_FROM/openldapCA.key" ]]; then
    action "Error: --ca-from '$CA_FROM' missing openldapCA.crt or openldapCA.key" >&2
    exit 1
  fi
  if [[ -f "$CA_CERT_PATH" ]] && cmp -s "$CA_FROM/openldapCA.crt" "$CA_CERT_PATH"; then
    log "CA already in sync with $CA_FROM - no copy."
  else
    action "Importing CA from $CA_FROM ..."
    cp "$CA_FROM/openldapCA.crt" "$CA_CERT_PATH"
    cp "$CA_FROM/openldapCA.key" "$CA_KEY_PATH"
    chmod 600 "$CA_KEY_PATH"
    chmod 644 "$CA_CERT_PATH"
    # New CA means we must regen the server cert against it
    FORCE_LDAP="yes"
  fi
fi

# === CA: generate if missing or --regen-ca ===
if [[ "$REGEN_CA" == "yes" || ! -f "$CA_CERT_PATH" ]]; then
  action "Generating CA certificate (ECDSA P-384, ${CA_DAYS}d)..."
  openssl ecparam -genkey -name secp384r1 -noout -out "$CA_KEY_PATH"
  openssl req -new -x509 -key "$CA_KEY_PATH" -days "$CA_DAYS" -out "$CA_CERT_PATH" -subj "/CN=OpenLDAP-CA"
  chmod 600 "$CA_KEY_PATH"
  chmod 644 "$CA_CERT_PATH"
  # CA regen invalidates server cert chain → force LDAP renewal
  FORCE_LDAP="yes"
fi

# === Decide if LDAP cert needs renewal ===
NEED_LDAP="no"
REASON=""
if [[ "$FORCE_LDAP" == "yes" ]]; then
  NEED_LDAP="yes"; REASON="--force"
elif [[ ! -f "$LDAP_CRT_PATH" || ! -f "$LDAP_KEY_PATH" ]]; then
  NEED_LDAP="yes"; REASON="missing"
else
  THRESHOLD_SECS=$(( RENEW_THRESHOLD_DAYS * 86400 ))
  if ! openssl x509 -in "$LDAP_CRT_PATH" -checkend "$THRESHOLD_SECS" -noout >/dev/null 2>&1; then
    EXPIRY=$(openssl x509 -in "$LDAP_CRT_PATH" -enddate -noout | cut -d= -f2)
    NEED_LDAP="yes"; REASON="expires within ${RENEW_THRESHOLD_DAYS}d (notAfter: $EXPIRY)"
  fi
fi

if [[ "$NEED_LDAP" == "yes" ]]; then
  action "Renewing OpenLDAP certificate ($REASON, ECDSA P-384, ${LDAP_DAYS}d)..."
  openssl ecparam -genkey -name secp384r1 -noout -out "$LDAP_KEY_PATH"
  cat > "$OPENSSL_CNF" <<EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $CN

[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $SAN
EOF
  openssl req -new -key "$LDAP_KEY_PATH" -out "$CSR_PATH" -config "$OPENSSL_CNF"
  openssl x509 -req -in "$CSR_PATH" -CA "$CA_CERT_PATH" -CAkey "$CA_KEY_PATH" -CAcreateserial \
    -out "$LDAP_CRT_PATH" -days "$LDAP_DAYS" -extensions v3_req -extfile "$OPENSSL_CNF"
  chmod 600 "$LDAP_KEY_PATH"
  chmod 644 "$LDAP_CRT_PATH"
  RENEWED="yes"
else
  EXPIRY=$(openssl x509 -in "$LDAP_CRT_PATH" -enddate -noout | cut -d= -f2)
  log "LDAP certificate still valid (notAfter: $EXPIRY) - no action."
fi

# === Permissions for the openldap container (uid 101, gid 102) ===
# Try passwordless sudo, then direct chown (root), else best-effort.
if [ "$(id -u)" -eq 0 ]; then
  chown -R 101:102 "$CERT_DIR"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo chown -R 101:102 "$CERT_DIR"
else
  chown -R 101:102 "$CERT_DIR" 2>/dev/null \
    || log "Note: could not chown $CERT_DIR to 101:102 (need root). Run 'sudo chown -R 101:102 $CERT_DIR' manually."
fi

# === Cleanup ===
rm -f "$CSR_PATH" "$OPENSSL_CNF" "$CERT_DIR/openldapCA.srl"

# === Container restart (only if anything renewed) ===
if [[ "$RENEWED" == "yes" ]]; then
  action "Certificates renewed in $CERT_DIR"
  if [[ "$RESTART_CONTAINER" == "yes" ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
      action "Restarting container '$CONTAINER_NAME' to pick up new certs..."
      docker restart "$CONTAINER_NAME" >/dev/null
      action "Container '$CONTAINER_NAME' restarted."
    else
      action "Container '$CONTAINER_NAME' not running - skip restart."
    fi
  else
    log "Note: slapd loads TLS at startup. Restart '$CONTAINER_NAME' to apply the new cert (or rerun with --restart)."
  fi
else
  log "No renewal needed."
fi
