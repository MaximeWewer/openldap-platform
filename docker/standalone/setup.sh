#!/bin/bash
# Bootstrap the standalone OpenLDAP deployment:
#   - slapadd cn=config from init-config/
#   - slapadd initial data from ../base-ldifs/
#   - fix permissions and start docker compose
set -euo pipefail

# === Configuration ===
IMAGE="cleanstart/openldap:2.6.13"

# Derive the ldap uid/gid from the image instead of hardcoding them. The
# cleanstart/openldap tag is mutable and the ldap user's ids have changed
# between builds (seen as both 100:101 and 101:102). Hardcoding makes the
# post-slapadd chown mismatch slapd's runtime user (started with -u ldap
# -g ldap), so the container crashes on the files it cannot read. Read the
# real ids from the image's /etc/passwd; fall back to 101:102 if unavailable.
read_ldap_ids() {
  local cid tmp pw
  cid=$(docker create "$IMAGE" 2>/dev/null) || return 1
  tmp=$(mktemp)
  docker cp "$cid":/etc/passwd "$tmp" >/dev/null 2>&1
  docker rm -f "$cid" >/dev/null 2>&1 || true
  pw=$(grep '^ldap:' "$tmp" 2>/dev/null); rm -f "$tmp"
  [ -n "$pw" ] || return 1
  LDAP_UID=$(printf '%s' "$pw" | cut -d: -f3)
  LDAP_GID=$(printf '%s' "$pw" | cut -d: -f4)
  [ -n "$LDAP_UID" ] && [ -n "$LDAP_GID" ]
}
if read_ldap_ids; then
  echo "Derived ldap uid:gid from ${IMAGE} = ${LDAP_UID}:${LDAP_GID}"
else
  LDAP_UID=101; LDAP_GID=102
  echo "WARNING: could not read ldap uid/gid from ${IMAGE}; falling back to ${LDAP_UID}:${LDAP_GID}" >&2
fi
LDAP_HOST="localhost"
LDAP_PORT="389"
BASE_DN="dc=example,dc=org"
LOCAL_ADMIN_DN="cn=admin,ou=users,$BASE_DN"
CONFIG_ADMIN="cn=adminconfig,cn=config"

SLAPD_DIR="./data/slapd.d"
DATA_DIR="./data/openldap-data"
ACCESSLOG_DIR="./data/accesslog-data"

VOLUMES=(
  -v "$(pwd)/data/slapd.d:/etc/openldap/slapd.d"
  -v "$(pwd)/data/openldap-data:/var/lib/openldap/openldap-data"
  -v "$(pwd)/data/accesslog-data:/var/lib/openldap/accesslog-data"
)

# === Check for clean state ===
# slapadd loads entries straight into the mdb backend, bypassing the ppolicy
# overlay - so olcPPolicyHashCleartext never sees these writes and any cleartext
# userPassword in the seed LDIFs lands in the directory verbatim. Hash them here
# instead. Values already carrying a {SCHEME} prefix, or base64 (::), pass
# through untouched, so this stays idempotent and safe over custom LDIFs.
hash_ldif_passwords() {
  local in="$1" out="$2" line pw
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "userPassword: {"*|"userPassword:: "*)
        printf '%s\n' "$line" >> "$out" ;;
      "userPassword: "*)
        pw=${line#userPassword: }
        printf 'userPassword: %s\n' \
          "$(docker run --rm --entrypoint slappasswd "$IMAGE" -s "$pw")" >> "$out" ;;
      *)
        printf '%s\n' "$line" >> "$out" ;;
    esac
  done < "$in"
}

if [ -d "$SLAPD_DIR" ] && [ "$(ls -A $SLAPD_DIR 2>/dev/null)" ]; then
  if [[ "${1:-}" == "--reset" ]]; then
    echo "Resetting existing data..."
    docker compose --profile metrics down 2>/dev/null || true
    docker run --rm -v "$(pwd)/data:/data" alpine:latest sh -c "rm -rf /data/slapd.d/* /data/openldap-data/* /data/accesslog-data/*"
  else
    echo "Error: $SLAPD_DIR is not empty."
    echo "Run './setup.sh --reset' to wipe and reinitialize."
    exit 1
  fi
fi

mkdir -p "$SLAPD_DIR" "$DATA_DIR" "$ACCESSLOG_DIR"

# === Step 1: Bootstrap cn=config ===
echo "=== Bootstrapping cn=config ==="
docker run --rm --user root \
  "${VOLUMES[@]}" \
  -v "$(pwd)/init-config:/init-config:ro" \
  --entrypoint slapadd "$IMAGE" \
  -n 0 -F /etc/openldap/slapd.d -l /init-config/slapd-config.ldif

# === Step 2: Build combined data LDIF ===
echo "=== Loading initial data ==="
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
{
  for ldif in \
    ../base-ldifs/01-base.ldif \
    ../base-ldifs/02-org-ou.ldif \
    ../base-ldifs/03-users.ldif \
    ../base-ldifs/04-service-accounts.ldif \
    ../base-ldifs/05-groups.ldif \
    ../base-ldifs/06-default-ppolicy.ldif; do
    sed 's/\r$//' "$ldif"
    echo ""
    echo ""
  done
} > "$TMP_DIR/all-data.raw.ldif"

echo "=== Hashing seeded passwords ==="
hash_ldif_passwords "$TMP_DIR/all-data.raw.ldif" "$TMP_DIR/all-data.ldif"
rm -f "$TMP_DIR/all-data.raw.ldif"

docker run --rm --user root \
  "${VOLUMES[@]}" \
  -v "$TMP_DIR:/init-data:ro" \
  --entrypoint slapadd "$IMAGE" \
  -n 1 -F /etc/openldap/slapd.d -l /init-data/all-data.ldif

# === Step 3: Fix permissions ===
echo "=== Fixing permissions ==="
docker run --rm --user root \
  "${VOLUMES[@]}" \
  alpine:latest sh -c "chown -R ${LDAP_UID}:${LDAP_GID} /etc/openldap/slapd.d /var/lib/openldap/openldap-data /var/lib/openldap/accesslog-data"

# === Step 4: Start containers ===
# Self Service Password config. Rendered once, then left alone - the keyphrase
# encrypts reset tokens and session cookies, so regenerating it on every run
# would invalidate every token already in flight.
if [ ! -f ./ssp.conf.php ]; then
  echo "=== Rendering ssp.conf.php (random keyphrase) ==="
  SSP_KEYPHRASE=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-32)
  sed "s|__SSP_KEYPHRASE__|${SSP_KEYPHRASE}|" \
    ./ssp.conf.php.example > ./ssp.conf.php
  chmod 600 ./ssp.conf.php
else
  echo "=== ssp.conf.php already present - keeping its keyphrase ==="
fi

# phpLDAPadmin's Laravel APP_KEY. Generated once per deployment into .env
# (compose reads that file automatically) rather than shipped as a literal in
# the compose file, where every install would share the same session/cookie key.
ensure_app_key() {
  if [ -f .env ] && grep -q '^PHPLDAPADMIN_APP_KEY=.\+' .env; then
    return 0
  fi
  echo "=== Generating PHPLDAPADMIN_APP_KEY into .env ==="
  printf 'PHPLDAPADMIN_APP_KEY=base64:%s\n' "$(head -c 32 /dev/urandom | base64)" >> .env
}
ensure_app_key

echo "=== Starting containers ==="
PROFILES=()
if [ "${ENABLE_EXPORTER:-false}" = "true" ]; then
  PROFILES+=(--profile metrics)
fi
docker compose "${PROFILES[@]}" up -d

echo "Waiting for OpenLDAP to start..."
for i in $(seq 1 30); do
  if ldapsearch -x -H "ldap://${LDAP_HOST}:${LDAP_PORT}" -b "" -s base "(objectClass=*)" namingContexts >/dev/null 2>&1; then
    echo "OpenLDAP is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Error: OpenLDAP did not start within 30 seconds."
    docker logs openldap 2>&1 | tail -10
    exit 1
  fi
  sleep 1
done

echo ""
echo "LDAP setup completed."
echo "  Admin DN:        $LOCAL_ADMIN_DN"
echo "  Config Admin DN: $CONFIG_ADMIN"
echo "  Base DN:         $BASE_DN"
echo "  LDAP:            ldap://${LDAP_HOST}:${LDAP_PORT}"
echo "  phpLDAPadmin:    http://localhost:8080"
echo "  SSP:             http://localhost:8088"
echo ""
echo "For day-to-day admin (users, groups, ppolicy, diagnostics), use openldap-cli:"
echo "  https://github.com/maximewewer/openldap-cli"
