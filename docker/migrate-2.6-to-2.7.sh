#!/usr/bin/env bash
# =============================================================================
# Migrate a Compose stack from OpenLDAP 2.6 to 2.7.
#
# OpenLDAP 2.7 changed the back-mdb on-disk format, so ./data cannot be
# carried over: slapd 2.7 refuses to open it with
#   MDB_INVALID: File is not an LMDB file (-30793)
#
# What this does, in order:
#   1. read the running server's version and stop if it already matches the
#      target - there is nothing to migrate
#   2. dump the data tree over LDAP as the rootDN (openldap-cli)
#   3. stop the stack and move ./data aside, keeping it for a rollback
#   4. rebuild cn=config with the TARGET image's own slapadd
#   5. point docker-compose.yml at the target image and start the stack
#   6. restore the dump and verify it entry by entry
#
# Nothing is deleted: the old ./data is renamed, not removed.
#
# Usage:
#   docker/migrate-2.6-to-2.7.sh [--image TAG] [--yes] <stack-dir>
#
#   <stack-dir>   standalone | ha-active-active | ha-active-passive
#   --image TAG   target image (default: cleanstart/openldap:2.7.1)
#   --config-ldif PATH
#                 cn=config LDIF to rebuild from. Defaults to
#                 init-config/slapd-config.ldif, which only the standalone
#                 stack keeps on disk; the HA stacks render theirs per node,
#                 so they are handed back to setup-node.sh after the dump.
#   --yes         skip the confirmation prompt
# =============================================================================
set -euo pipefail

LOG()  { printf '[migrate] %s\n' "$*"; }
WARN() { printf '[migrate] WARNING: %s\n' "$*" >&2; }
DIE()  { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="$REPO_ROOT/scripts/openldap-migrate.sh"
[ -x "$SHARED" ] || DIE "missing $SHARED"

TARGET_IMAGE="cleanstart/openldap:2.7.1"
ASSUME_YES="false"
STACK=""
CONFIG_LDIF_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) TARGET_IMAGE="$2"; shift 2 ;;
    --config-ldif) CONFIG_LDIF_OVERRIDE="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES="true"; shift ;;
    -*) DIE "unknown option: $1" ;;
    *) STACK="$1"; shift ;;
  esac
done
[ -n "$STACK" ] || DIE "usage: $0 [--image TAG] [--yes] <stack-dir>"

# A bare name is one of the shipped stacks; anything else is taken as a path,
# so the script also works on a stack copied elsewhere.
if [ -f "$REPO_ROOT/docker/$STACK/docker-compose.yml" ]; then
  STACK_DIR="$REPO_ROOT/docker/$STACK"
elif [ -f "$STACK/docker-compose.yml" ]; then
  STACK_DIR="$(cd "$STACK" && pwd)"
else
  DIE "no docker-compose.yml in '$STACK' nor in $REPO_ROOT/docker/$STACK"
fi
cd "$STACK_DIR"

TARGET_MAJOR="$(printf '%s' "${TARGET_IMAGE##*:}" | cut -d. -f1,2)"

# --------------------------------------------------------------------------
# openldap-cli: use the one on PATH, otherwise fetch it next to this run and
# verify it against the checksums the project publishes beside the artefact.
# --------------------------------------------------------------------------
CLI_VERSION="${CLI_VERSION:-v2026.10.1}"
CLI="$(command -v openldap-cli || true)"
TMPBIN=""
if [ -z "$CLI" ]; then
  TMPBIN="$(mktemp -d)"
  trap 'rm -rf "$TMPBIN"' EXIT
  TARBALL="openldap-cli_${CLI_VERSION}_linux_amd64.tar.gz"
  BASE="https://github.com/maximewewer/openldap-cli/releases/download/${CLI_VERSION}"
  LOG "fetching openldap-cli ${CLI_VERSION}"
  curl --retry 3 -fsSL "$BASE/$TARBALL" -o "$TMPBIN/cli.tgz" || DIE "download failed"
  curl --retry 3 -fsSL "$BASE/checksums.txt" -o "$TMPBIN/sums" || DIE "cannot fetch checksums.txt"
  WANT="$(awk -v f="$TARBALL" '$2 == f || $2 == "*" f { print $1; exit }' "$TMPBIN/sums")"
  [ -n "$WANT" ] || DIE "$TARBALL absent from checksums.txt"
  GOT="$(sha256sum "$TMPBIN/cli.tgz" | cut -d' ' -f1)"
  [ "$WANT" = "$GOT" ] || DIE "checksum mismatch for $TARBALL"
  tar xzf "$TMPBIN/cli.tgz" -C "$TMPBIN"
  CLI="$TMPBIN/openldap-cli"
  chmod +x "$CLI"
fi

# --------------------------------------------------------------------------
# Connection details - the stack's own .env wins, these are the defaults the
# shipped compose files use.
# --------------------------------------------------------------------------
[ -f .env ] && . ./.env
BASE_DN="${LDAP_BASE_DN:-dc=example,dc=org}"
ADMIN_DN="${LDAP_ADMIN_DN:-cn=admin,${BASE_DN}}"
CONFIG_DN="${LDAP_CONFIG_DN:-cn=adminconfig,cn=config}"
PORT="${LDAP_PORT:-389}"
URL="ldap://127.0.0.1:${PORT}"

[ -n "${LDAP_ADMIN_PASSWORD:-}" ] || DIE "LDAP_ADMIN_PASSWORD is not set - export it or put it in $STACK_DIR/.env"
[ -n "${LDAP_CONFIG_PASSWORD:-}" ] || WARN "LDAP_CONFIG_PASSWORD is not set - the version probe and the cn=config record will be skipped"

WORK="./migration-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
chmod 700 "$WORK"
ADM_PW="$WORK/admin.pw"; printf '%s' "$LDAP_ADMIN_PASSWORD" > "$ADM_PW"; chmod 600 "$ADM_PW"
CFG_PW=""
if [ -n "${LDAP_CONFIG_PASSWORD:-}" ]; then
  CFG_PW="$WORK/config.pw"; printf '%s' "$LDAP_CONFIG_PASSWORD" > "$CFG_PW"; chmod 600 "$CFG_PW"
fi

# --------------------------------------------------------------------------
# 1. Is there anything to migrate?
# --------------------------------------------------------------------------
running_major() {
  [ -n "$CFG_PW" ] || return 1
  LDAP_URL="$URL" LDAP_BASE_DN="$BASE_DN" LDAP_BIND_DN="$ADMIN_DN" \
  LDAP_BIND_PW_FILE="$ADM_PW" LDAP_CONFIG_BIND_DN="$CONFIG_DN" \
  LDAP_CONFIG_BIND_PW_FILE="$CFG_PW" \
    "$CLI" -o json search '(objectClass=*)' --base 'cn=Monitor' --scope base \
      --config-bind --attrs monitoredInfo 2>/dev/null \
    | sed -n 's/.*slapd \([0-9]*\.[0-9]*\)\.[0-9]*.*/\1/p' | head -1
}

CURRENT_MAJOR="$(running_major || true)"
if [ -n "$CURRENT_MAJOR" ]; then
  LOG "running slapd: $CURRENT_MAJOR    target: $TARGET_MAJOR"
  if [ "$CURRENT_MAJOR" = "$TARGET_MAJOR" ]; then
    LOG "already on $TARGET_MAJOR - nothing to migrate"
    rm -rf "$WORK"
    exit 0
  fi
else
  WARN "could not read the running version from cn=Monitor (needs LDAP_CONFIG_PASSWORD and the monitor database)"
  WARN "continuing: the dump and the restore verify themselves either way"
fi

cat <<EOF

  stack      : $STACK_DIR
  from       : ${CURRENT_MAJOR:-unknown}
  to         : $TARGET_IMAGE
  dump       : $WORK
  old data   : ./data -> ./data.pre-${TARGET_MAJOR}-<timestamp>  (kept)

EOF
if [ "$ASSUME_YES" != "true" ]; then
  printf '  Proceed? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes) ;; *) LOG "aborted"; exit 1 ;; esac
fi

# --------------------------------------------------------------------------
# 2. Dump
# --------------------------------------------------------------------------
LOG "=== 1/5 dump ==="
DUMP_ARGS="--url $URL --base-dn $BASE_DN --bind-dn $ADMIN_DN --password-file $ADM_PW --cli $CLI"
# shellcheck disable=SC2086
if [ -n "$CFG_PW" ]; then
  "$SHARED" dump $DUMP_ARGS --config-bind-dn "$CONFIG_DN" --config-password-file "$CFG_PW" "$WORK"
else
  "$SHARED" dump $DUMP_ARGS "$WORK"
fi

# --------------------------------------------------------------------------
# 3. Stop and set the old data aside
# --------------------------------------------------------------------------
LOG "=== 2/5 stopping the stack ==="
docker compose --profile metrics down || docker compose down

OLD_DATA="./data.pre-${TARGET_MAJOR}-$(date -u +%Y%m%d-%H%M%S)"
LOG "=== 3/5 moving ./data aside -> $OLD_DATA ==="
[ -d ./data ] || DIE "no ./data in $STACK_DIR - is this the right stack?"
mv ./data "$OLD_DATA"
mkdir -p ./data/slapd.d ./data/openldap-data ./data/accesslog-data

# --------------------------------------------------------------------------
# 4. Rebuild cn=config with the TARGET image's slapadd
#
# Using the target image's own binary is what keeps 2.7 reading what 2.7
# wrote; it is also why the Compose stacks never hit the tooling-version skew
# the Helm chart has to work around.
# --------------------------------------------------------------------------
LOG "=== 4/5 rebuilding cn=config with ${TARGET_IMAGE} ==="

# The HA stacks render init-config/slapd-config.ldif.tmpl per node, from the
# serverID / peer values setup-node.sh was given, and never keep the result on
# disk. Re-deriving that here would be a second, diverging copy of
# setup-node.sh, so the script hands the stack back instead - with the dump
# already taken and ./data already set aside, which is the part that has to
# happen while the old server is still around.
CONFIG_LDIF="${CONFIG_LDIF_OVERRIDE:-init-config/slapd-config.ldif}"
if [ ! -f "$CONFIG_LDIF" ]; then
  cat <<EOF

[migrate] The dump is taken and the old data is at $OLD_DATA.

  This stack renders its cn=config from a template per node, so finish it
  with the stack's own setup script, which rebuilds cn=config with the
  target image's slapadd:

      cd $STACK_DIR
      sed -i 's|image: cleanstart/openldap:[^ ]*|image: ${TARGET_IMAGE}|' docker-compose.yml
      ./setup-node.sh <the same arguments you used originally>

  It seeds base-ldifs as well; wipe the data tree it just created before
  restoring, or the restore will refuse a non-empty target:

      docker compose down
      docker run --rm -v "\$(pwd)/data:/data" alpine sh -c 'rm -rf /data/openldap-data/*'
      docker compose up -d openldap

  Then:

      $SHARED restore $DUMP_ARGS $WORK
      $SHARED verify  $DUMP_ARGS $WORK

  Every node of the mesh must be reseeded from this dump: entryCSN and
  contextCSN are not carried over, so a 2.7 node must not be left to
  syncrepl from a 2.6 peer.

EOF
  exit 0
fi

# Same method as the stacks' setup scripts: the runtime image is distroless,
# so there is no `cat` to run inside it - copy /etc/passwd out of a created
# container instead. Getting this wrong is not cosmetic: the compose
# entrypoint starts slapd with `-u ldap -g ldap`, so it drops to the image's
# own ids and cannot read a tree chowned to someone else. The 2.7.1 runtime
# image uses 102:103 where 2.6.13 used 101:102.
read_ldap_ids() {
  local cid tmp pw
  cid=$(docker create "$TARGET_IMAGE" 2>/dev/null) || return 1
  tmp=$(mktemp)
  docker cp "$cid":/etc/passwd "$tmp" >/dev/null 2>&1
  docker rm -f "$cid" >/dev/null 2>&1 || true
  pw=$(grep '^ldap:' "$tmp" 2>/dev/null); rm -f "$tmp"
  [ -n "$pw" ] || return 1
  LDAP_UID="$(printf '%s' "$pw" | cut -d: -f3)"
  LDAP_GID="$(printf '%s' "$pw" | cut -d: -f4)"
  [ -n "$LDAP_UID" ] && [ -n "$LDAP_GID" ]
}
if read_ldap_ids; then
  LOG "ldap uid:gid in $TARGET_IMAGE = ${LDAP_UID}:${LDAP_GID}"
else
  DIE "could not read the ldap uid/gid out of $TARGET_IMAGE - refusing to guess: a wrong owner makes slapd exit on the files it cannot read, and ./data has already been set aside at $OLD_DATA"
fi

docker run --rm --user root \
  -v "$(pwd)/data/slapd.d:/etc/openldap/slapd.d" \
  -v "$(pwd)/data/openldap-data:/var/lib/openldap/openldap-data" \
  -v "$(pwd)/data/accesslog-data:/var/lib/openldap/accesslog-data" \
  -v "$(pwd)/init-config:/init-config:ro" \
  --entrypoint slapadd "$TARGET_IMAGE" \
  -n 0 -F /etc/openldap/slapd.d -l "/init-config/$(basename "$CONFIG_LDIF")"

# The runtime image is distroless, so the chown runs from a shell image
# rather than from it.
docker run --rm -v "$(pwd)/data:/data" alpine:3.24 \
  chown -R "${LDAP_UID}:${LDAP_GID}" /data

# --------------------------------------------------------------------------
# 5. Point the stack at the target image and bring it up
# --------------------------------------------------------------------------
LOG "=== 5/5 starting ${TARGET_IMAGE} ==="
cp docker-compose.yml "docker-compose.yml.pre-${TARGET_MAJOR}"
sed -i "s|image: cleanstart/openldap:[^[:space:]]*|image: ${TARGET_IMAGE}|" docker-compose.yml
docker compose up -d openldap

LOG "waiting for the directory to answer"
end=$(( $(date +%s) + 120 ))
until LDAP_URL="$URL" LDAP_BASE_DN="$BASE_DN" LDAP_BIND_DN="$ADMIN_DN" \
      LDAP_BIND_PW_FILE="$ADM_PW" "$CLI" whoami >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$end" ] || DIE "the new stack never answered - check 'docker compose logs openldap'; ./data is still at $OLD_DATA"
  sleep 3
done

# shellcheck disable=SC2086
"$SHARED" restore $DUMP_ARGS "$WORK"
# shellcheck disable=SC2086
"$SHARED" verify  $DUMP_ARGS "$WORK"

cat <<EOF

[migrate] done.

  the previous data directory is kept at:
      $STACK_DIR/$OLD_DATA
  the dump and its manifest at:
      $STACK_DIR/$WORK
  the previous compose file at:
      $STACK_DIR/docker-compose.yml.pre-${TARGET_MAJOR}

  Roll back by restoring those two and running 'docker compose up -d'.
  Remove them once the new stack has proven itself - the dump holds
  password hashes, so keep it on an encrypted partition until then.

EOF
