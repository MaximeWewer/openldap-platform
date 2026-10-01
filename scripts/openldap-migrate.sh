#!/bin/sh
# =============================================================================
# OpenLDAP 2.6 -> 2.7 migration
#
# OpenLDAP 2.7 changed the back-mdb on-disk format: a data directory written
# under 2.6 makes slapd 2.7 refuse to start with
#
#   mdb_db_open: database "<suffix>" cannot be opened:
#   MDB_INVALID: File is not an LMDB file (-30793)
#
# so the move is a dump and reload, not an in-place upgrade. This does it
# entirely over LDAP with openldap-cli - no shell in the server image, no
# volume access, no slapcat/slapadd version matching. `backup restore` sends
# the Relax control, so the password HASHES carry over and users keep the
# credentials they already have.
#
# cn=config is NOT migrated and does not need to be: the chart rebuilds it
# from values on a first bootstrap, and the compose stacks from their
# slapd-config.ldif. `dump` still records it, as a reference for diffing the
# new tree against the old one.
#
# Usage:
#   migrate-2.6-to-2.7.sh dump    --url ldap://OLD:389 [options] <dir>
#   migrate-2.6-to-2.7.sh restore --url ldap://NEW:389 [options] <dir>
#   migrate-2.6-to-2.7.sh verify  --url ldap://NEW:389 [options] <dir>
#
# Options (all three subcommands):
#   --url URL            LDAP URL of the server to act on         (required)
#   --base-dn DN         directory suffix                         (required)
#   --bind-dn DN         rootDN - a non-root bind silently omits
#                        entries and userPassword                 (required)
#   --password-file F    file holding the rootDN password         (required)
#   --config-bind-dn DN  cn=config rootDN, for the dump record    (optional)
#   --config-password-file F                                      (optional)
#   --cli PATH           openldap-cli binary      (default: from $PATH)
#   --allow-missing-passwords
#                        `dump` only: proceed although some accounts carry no
#                        userPassword. Only correct when they genuinely have
#                        none - otherwise the bind was not the rootDN and the
#                        hashes were filtered out by the ACLs.
#
# <dir> holds the dump and the manifest `verify` checks against.
#
# Between `dump` and `restore` you install the 2.7 release on an EMPTY data
# volume. Reusing the old PVC is the one thing that cannot work.
# =============================================================================
set -eu

LOG()  { printf '[migrate] %s\n' "$*"; }
WARN() { printf '[migrate] WARNING: %s\n' "$*" >&2; }
DIE()  { printf '[migrate] ERROR: %s\n' "$*" >&2; exit 1; }

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in dump|restore|verify) ;; *) DIE "usage: $0 dump|restore|verify --url ... <dir>" ;; esac

URL=""; BASE_DN=""; BIND_DN=""; PW_FILE=""
CFG_BIND_DN=""; CFG_PW_FILE=""; CLI="openldap-cli"; DIR=""; ALLOW_MISSING_PW="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --url)                  URL="$2";         shift 2 ;;
    --base-dn)              BASE_DN="$2";     shift 2 ;;
    --bind-dn)              BIND_DN="$2";     shift 2 ;;
    --password-file)        PW_FILE="$2";     shift 2 ;;
    --config-bind-dn)       CFG_BIND_DN="$2"; shift 2 ;;
    --config-password-file) CFG_PW_FILE="$2"; shift 2 ;;
    --cli)                  CLI="$2";         shift 2 ;;
    --allow-missing-passwords) ALLOW_MISSING_PW="true"; shift ;;
    -*)                     DIE "unknown option: $1" ;;
    *)                      DIR="$1";         shift ;;
  esac
done

[ -n "$URL" ]     || DIE "--url is required"
[ -n "$BASE_DN" ] || DIE "--base-dn is required"
[ -n "$BIND_DN" ] || DIE "--bind-dn is required"
[ -n "$PW_FILE" ] || DIE "--password-file is required"
[ -f "$PW_FILE" ] || DIE "password file not found: $PW_FILE"
[ -n "$DIR" ]     || DIE "a working directory is required"
command -v "$CLI" >/dev/null 2>&1 || [ -x "$CLI" ] || DIE "openldap-cli not found: $CLI"

DUMP="$DIR/data.ldif"
CFGDUMP="$DIR/config-reference.ldif"
MANIFEST="$DIR/manifest.txt"

# The CLI reads these natively, so nothing lands on a command line where
# /proc/<pid>/cmdline would expose it.
export LDAP_URL="$URL" LDAP_BASE_DN="$BASE_DN" LDAP_BIND_DN="$BIND_DN"
export LDAP_BIND_PW_FILE="$PW_FILE"
[ -n "$CFG_BIND_DN" ] && export LDAP_CONFIG_BIND_DN="$CFG_BIND_DN"
[ -n "$CFG_PW_FILE" ] && export LDAP_CONFIG_BIND_PW_FILE="$CFG_PW_FILE"

ldap() { "$CLI" "$@"; }

# Counting from the LDIF rather than from a second search keeps `verify`
# honest: it compares what was written against what the new server returns.
# `grep -c` already prints 0 when nothing matches AND exits 1, so the obvious
# `grep -c ... || echo 0` emits TWO lines and every arithmetic test downstream
# fails with "Illegal number".
count_re() { _n=$(grep -c "$1" "$2" 2>/dev/null) || _n=0; printf '%s' "$_n"; }

count_dns()    { count_re '^dn:' "$1"; }
count_hashes() { count_re '^userPassword' "$1"; }
# Entries that are accounts, so a hash short of this number means someone
# comes back unable to log in.
count_people() { _n=$(grep -ci '^objectClass: inetOrgPerson' "$1" 2>/dev/null) || _n=0; printf '%s' "$_n"; }

# --------------------------------------------------------------------------
case "$CMD" in

dump)
  mkdir -p "$DIR"
  LOG "source: $URL ($BASE_DN) as $BIND_DN"
  ldap whoami >/dev/null || DIE "cannot bind to $URL as $BIND_DN"

  LOG "dumping the data tree"
  # No --operational: those attributes are server-maintained and `restore`
  # strips them anyway. entryUUID and entryCSN are NOT carried over - the
  # restored tree is a new directory, so every replica must be reseeded from
  # it rather than left to syncrepl from an old one.
  ldap backup data "$DUMP"

  ENTRIES=$(count_dns "$DUMP")
  HASHES=$(count_hashes "$DUMP")
  PEOPLE=$(count_people "$DUMP")
  [ "$ENTRIES" -gt 0 ] || DIE "the dump is empty - refusing to continue"
  LOG "  $ENTRIES entries, $PEOPLE accounts, $HASHES userPassword hashes"

  # Not "> 0": slapd applies its ACLs to the dump, and the usual
  # `by self write` clause hands a non-root bind exactly ONE hash - its own.
  # A dump with some hashes is the dangerous case, not the obvious one.
  if [ "$HASHES" -lt "$PEOPLE" ]; then
    MISSING=$((PEOPLE - HASHES))
    WARN "$MISSING of $PEOPLE accounts carry no userPassword"
    WARN "slapd filters the dump through its ACLs: unless $BIND_DN is the"
    WARN "rootDN, the hashes it may not read are silently absent and those"
    WARN "users come back unable to log in."
    if [ "$ALLOW_MISSING_PW" = "true" ]; then
      WARN "--allow-missing-passwords given - continuing anyway"
    else
      DIE "re-run the dump as the database rootDN, or pass --allow-missing-passwords if those accounts genuinely have no password"
    fi
  fi

  if [ -n "$CFG_BIND_DN" ]; then
    LOG "recording cn=config for reference (not restored)"
    ldap backup config "$CFGDUMP" || WARN "cn=config dump failed - continuing, it is a reference only"
  else
    LOG "skipping the cn=config record (--config-bind-dn not given)"
  fi

  {
    echo "source_url=$URL"
    echo "base_dn=$BASE_DN"
    echo "entries=$ENTRIES"
    echo "accounts=$PEOPLE"
    echo "password_hashes=$HASHES"
    echo "dumped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$MANIFEST"
  LOG "dump complete -> $DUMP"
  LOG "next: install the 2.7 release on an EMPTY data volume, then run 'restore'"
  ;;

restore)
  [ -f "$DUMP" ]     || DIE "no dump at $DUMP - run 'dump' first"
  [ -f "$MANIFEST" ] || DIE "no manifest at $MANIFEST - run 'dump' first"
  LOG "target: $URL ($BASE_DN) as $BIND_DN"
  ldap whoami >/dev/null || DIE "cannot bind to $URL as $BIND_DN"

  # Restoring onto a populated tree is how you get half-merged state: each
  # existing entry fails on its own and the run still reads as a success.
  # `users list` prints a trailing "(N users)" tally; anything but 0 means
  # this is not a fresh install.
  TALLY=$(ldap users list 2>/dev/null | sed -n 's/^(\([0-9]*\) user.*/\1/p' | tail -1)
  if [ -n "${TALLY:-}" ] && [ "$TALLY" -gt 0 ]; then
    DIE "the target already holds $TALLY user(s) - restore onto a FRESH install, or empty it first"
  fi

  LOG "restoring $(count_dns "$DUMP") entries"
  # --stop-on-error: a half-restored directory is worse than a failed run,
  # and the fix is almost always "the target was not empty".
  ldap backup restore "$DUMP" --stop-on-error
  LOG "restore complete - run 'verify' next"
  ;;

verify)
  [ -f "$MANIFEST" ] || DIE "no manifest at $MANIFEST"
  # shellcheck disable=SC1090
  . "$MANIFEST"
  LOG "target: $URL ($BASE_DN)"
  ldap whoami >/dev/null || DIE "cannot bind to $URL as $BIND_DN"

  ldap backup data "$DIR/after.ldif" >/dev/null
  AFTER=$(count_dns "$DIR/after.ldif")
  AFTER_HASHES=$(count_hashes "$DIR/after.ldif")

  LOG "entries   : $entries (source) -> $AFTER (target)"
  LOG "pw hashes : $password_hashes (source) -> $AFTER_HASHES (target)"

  RC=0
  [ "$AFTER" = "$entries" ] || { WARN "entry count differs"; RC=1; }
  [ "$AFTER_HASHES" = "$password_hashes" ] || { WARN "password hash count differs - some users would be locked out"; RC=1; }

  # A matching count is not the same as matching values: compare the stored
  # values themselves, since that is what decides whether anyone can log in.
  #
  # Only the values that were ALREADY hashed at the source. A directory seeded
  # by slapadd bypasses the ppolicy overlay, so it can legitimately hold
  # cleartext; the restore goes through LDAP, where olcPPolicyHashCleartext
  # hashes it on the way in. That difference is the overlay doing its job, not
  # a migration fault - the password itself is unchanged.
  TMPSRC=$(mktemp); TMPDST=$(mktemp)
  # LC_ALL=C: `comm` compares bytes, so the two inputs have to be sorted the
  # same way. A locale-aware sort orders them differently and comm then
  # reports "input is not in sorted order" and silently misreads the diff.
  grep '^userPassword: {' "$DUMP"           | LC_ALL=C sort > "$TMPSRC"
  grep '^userPassword: {' "$DIR/after.ldif" | LC_ALL=C sort > "$TMPDST"
  SRC_HASHED=$(count_re '^userPassword: {' "$DUMP")
  SRC_CLEAR=$((password_hashes - SRC_HASHED))

  # Every value hashed at the source must be present at the target. Not set
  # equality: the target legitimately holds MORE hashed values than the
  # source, one for each cleartext the ppolicy overlay hashed on the way in.
  MISSING=$(LC_ALL=C comm -23 "$TMPSRC" "$TMPDST" | grep -c . 2>/dev/null) || MISSING=0
  if [ "$MISSING" -eq 0 ]; then
    if [ "$SRC_HASHED" -gt 0 ]; then
      LOG "$SRC_HASHED pre-hashed password(s) carried over byte for byte"
    fi
  else
    WARN "$MISSING pre-hashed password(s) from the source are absent at the target"
    RC=1
  fi
  if [ "$SRC_CLEAR" -gt 0 ]; then
    LOG "$SRC_CLEAR password(s) were stored in cleartext at the source and were"
    LOG "  hashed by the target's ppolicy overlay on the way in - unchanged credentials"
  fi
  rm -f "$TMPSRC" "$TMPDST"

  if [ "$RC" -eq 0 ]; then
    LOG "migration verified"
  else
    DIE "verification failed - see the warnings above"
  fi
  ;;
esac
