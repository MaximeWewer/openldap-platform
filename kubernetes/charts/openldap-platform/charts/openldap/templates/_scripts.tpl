{{- /*
common.sh, shared by the sync ConfigMap and the migration one.

It lives here because the two ConfigMaps have different lifecycles: the
migration scripts have to exist during the PRE-upgrade phase, before the
chart's ordinary resources are applied, so they cannot sit in a ConfigMap
that is itself an ordinary resource. One source, two carriers.
*/ -}}
{{- define "openldap.script.common" -}}
#!/bin/sh
set -eu

LOG() { printf '[sync] %s\n' "$*"; }
DIE() { printf '[sync] ERROR: %s\n' "$*" >&2; exit 1; }

: "${LDAP_URL:?}"; : "${LDAP_BASE_DN:?}"; : "${LDAP_BIND_DN:?}"
: "${LDAP_USER_OU:?}"; : "${LDAP_GROUP_OU:?}"; : "${LDAP_POLICY_OU:?}"
: "${LDAP_MAIL_DOMAIN:?}"; : "${CLI_VERSION:?}"; : "${CLI_DOWNLOAD_URL:?}"
: "${KUBECTL_VERSION:?}"
[ -f /secrets/admin-password ] || DIE "admin password missing at /secrets/admin-password"
# The Secret is already mounted as a file, so with PASSWORD_FILES on we hand
# the CLI the path and the password never enters the environment - env is
# readable through /proc/<pid>/environ by anything sharing the pod. Falls
# back to the env var for CLI builds older than v2026.9.1, which is where
# LDAP_BIND_PW_FILE landed.
if [ "${PASSWORD_FILES:-false}" = "true" ]; then
  LDAP_BIND_PW_FILE=/secrets/admin-password; export LDAP_BIND_PW_FILE
else
  LDAP_BIND_PW="$(cat /secrets/admin-password)"; export LDAP_BIND_PW
fi

if ! command -v openldap-cli >/dev/null 2>&1; then
  LOG "Installing tooling (apk + openldap-cli ${CLI_VERSION} + kubectl ${KUBECTL_VERSION})"
  # Retry apk - mirrors are occasionally slow / transiently unreachable.
  APK_TRIES=0
  until apk add --no-cache curl ca-certificates jq openssl >/dev/null 2>&1; do
    APK_TRIES=$((APK_TRIES + 1))
    [ "$APK_TRIES" -ge 5 ] && DIE "apk add failed after 5 attempts"
    LOG "apk add: transient failure (try ${APK_TRIES}/5), retrying in 5s"
    sleep 5
  done
  # Both binaries land in $PATH and then bind to the directory as admin, so
  # neither is fetched unverified. `cli.sha256` / `cli.kubectlSha256` pin an
  # exact digest when set; otherwise verify against the checksum file each
  # project publishes next to the artefact.
  TARBALL="openldap-cli_${CLI_VERSION}_linux_amd64.tar.gz"
  curl --retry 3 --retry-delay 3 -fsSL "${CLI_DOWNLOAD_URL}/${CLI_VERSION}/${TARBALL}" -o /tmp/cli.tgz
  if [ -n "${CLI_SHA256:-}" ]; then
    CLI_WANT="${CLI_SHA256}"
  else
    curl --retry 3 --retry-delay 3 -fsSL "${CLI_DOWNLOAD_URL}/${CLI_VERSION}/checksums.txt" -o /tmp/cli.sums \
      || DIE "cannot fetch checksums.txt for openldap-cli ${CLI_VERSION} - pin cli.sha256 to install anyway"
    CLI_WANT=$(awk -v f="${TARBALL}" '$2 == f || $2 == "*" f { print $1; exit }' /tmp/cli.sums)
    [ -n "${CLI_WANT}" ] || DIE "${TARBALL} absent from checksums.txt"
  fi
  CLI_GOT=$(sha256sum /tmp/cli.tgz | cut -d' ' -f1)
  [ "${CLI_GOT}" = "${CLI_WANT}" ] \
    || DIE "openldap-cli checksum mismatch (want ${CLI_WANT}, got ${CLI_GOT})"
  tar -xzf /tmp/cli.tgz -C /usr/local/bin openldap-cli
  chmod +x /usr/local/bin/openldap-cli

  curl --retry 3 --retry-delay 3 -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  if [ -n "${KUBECTL_SHA256:-}" ]; then
    KUBECTL_WANT="${KUBECTL_SHA256}"
  else
    KUBECTL_WANT=$(curl --retry 3 --retry-delay 3 -fsSL \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
      || DIE "cannot fetch kubectl.sha256 for ${KUBECTL_VERSION} - pin cli.kubectlSha256 to install anyway")
  fi
  KUBECTL_GOT=$(sha256sum /tmp/kubectl | cut -d' ' -f1)
  [ "${KUBECTL_GOT}" = "${KUBECTL_WANT}" ] \
    || DIE "kubectl checksum mismatch (want ${KUBECTL_WANT}, got ${KUBECTL_GOT})"
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

  rm -f /tmp/cli.tgz /tmp/cli.sums /tmp/kubectl
fi

# Prefer flags + env over the config file (LDAP_* env vars are honoured
# natively by the CLI). Still write a config file so future ad-hoc `kubectl
# exec` sessions in the Job's pod work without env plumbing.
umask 077
mkdir -p /root
cat > /root/.openldap-cli.yaml <<EOF
default: helm
profiles:
  helm:
    url: ${LDAP_URL}
    base_dn: ${LDAP_BASE_DN}
    bind_dn: ${LDAP_BIND_DN}
    user_ou: ${LDAP_USER_OU}
    group_ou: ${LDAP_GROUP_OU}
    policy_ou: ${LDAP_POLICY_OU}
    mail_domain: ${LDAP_MAIL_DOMAIN}
EOF

wait_for_ldap() {
  end=$(( $(date +%s) + ${WAIT_TIMEOUT_SECONDS:-180} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if openldap-cli whoami >/dev/null 2>&1; then
      LOG "LDAP reachable, bind OK"
      return 0
    fi
    sleep "${WAIT_INTERVAL_SECONDS:-3}"
  done
  DIE "LDAP not reachable within ${WAIT_TIMEOUT_SECONDS:-180}s"
}

# -------------------------------------------------------------------------
# Per-entry OU support (values `users[].ou` / `groups[].ou`).
#
# The CLI takes its user and group containers from LDAP_USER_OU /
# LDAP_GROUP_OU, and only two verbs read them to BUILD a DN: `user add` and
# `group create`. Every other verb (info, set, delete, ppolicy assign,
# add-member, and the member resolution behind it) locates the entry with a
# subtree search from its container - so clearing the variable widens that
# search to the whole base DN and finds the entry in whatever OU it lives.
#
# `ldap_in <user-ou> <group-ou> <cmd...>` scopes both for one command; an
# empty string means "search from the base DN".
# -------------------------------------------------------------------------
DEFAULT_USER_OU="${LDAP_USER_OU}"
DEFAULT_GROUP_OU="${LDAP_GROUP_OU}"

ldap_in() {
  _uou="$1"; _gou="$2"; shift 2
  LDAP_USER_OU="$_uou" LDAP_GROUP_OU="$_gou" "$@"
}

# The version of the server actually answering, as `<major>.<minor>`.
# cn=Monitor carries it in monitoredInfo, which is operational and so has
# to be asked for by name. Needs the config bind.
running_major() {
  openldap-cli -o json search '(objectClass=*)' --base 'cn=Monitor' --scope base \
    --config-bind --attrs monitoredInfo 2>/dev/null \
    | jq -r '.entries[0].attrs.monitoredInfo[0] // empty' 2>/dev/null \
    | sed -n 's/.*slapd \([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p'
}

# `service-accounts`, `ou=service-accounts` and `ou=apps,ou=service-accounts`
# all normalise to a DN fragment relative to the base DN. Empty stays empty.
normalize_ou() {
  _ou=$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$_ou" ] || return 0
  case "$_ou" in
    ou=*) printf '%s' "$_ou" ;;
    *)    printf 'ou=%s' "$_ou" ;;
  esac
}

# The chart does not create containers on the fly: bootstrap owns them
# (directory.organizationalUnits). Failing here beats a bare "no such
# object" from the add, which says nothing about what to fix.
ensure_ou() {
  [ -n "${1:-}" ] || return 0
  openldap-cli search '(objectClass=*)' --base "$1,${LDAP_BASE_DN}" \
    --scope base -o json >/dev/null 2>&1 && return 0
  DIE "$1,${LDAP_BASE_DN} does not exist - add it to directory.organizationalUnits (or create it out-of-band) before declaring entries in it"
}

# -------------------------------------------------------------------------
# Secret helpers (backend=kubernetes).
# -------------------------------------------------------------------------
secret_name_for_user() { printf '%s-user-%s' "${RELEASE_FULLNAME}" "$1"; }

secret_password_exists() {
  kubectl -n "${RELEASE_NAMESPACE}" get secret "$(secret_name_for_user "$1")" >/dev/null 2>&1
}

secret_password_get() {
  kubectl -n "${RELEASE_NAMESPACE}" get secret "$(secret_name_for_user "$1")" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

# pwdChangedTime is maintained by the ppolicy overlay on every userPassword
# write, including the chart's own. Recording the value observed right after
# we set the password gives the cleanup CronJob an exact marker: if the
# directory later reports a different one, someone (Self Service Password,
# an admin, the user) has changed the password and the stored Secret is
# stale. Empty for entries never written over LDAP - slapadd bypasses the
# overlay, so seeded users have no pwdChangedTime at all.
#
# The DN is resolved rather than assembled from LDAP_USER_OU: with
# `users[].ou` the entry may sit anywhere under the base DN.
user_dn() {
  ldap_in "" "$DEFAULT_GROUP_OU" openldap-cli user info "$1" -o json 2>/dev/null \
    | jq -r '.dn // empty' 2>/dev/null || true
}

user_pwd_changed_time() {
  _dn=$(user_dn "$1")
  [ -n "$_dn" ] || return 0
  openldap-cli search '(objectClass=*)' \
    --base "$_dn" \
    --scope base --operational -o json 2>/dev/null \
    | jq -r '.entries[0].attrs.pwdChangedTime[0] // empty' 2>/dev/null || true
}

secret_password_put() {
  local uid="$1" pw="$2" name stamp
  name="$(secret_name_for_user "$uid")"
  stamp="$(user_pwd_changed_time "$uid")"
  kubectl -n "${RELEASE_NAMESPACE}" create secret generic "$name" \
    --from-literal=password="$pw" \
    --dry-run=client -o yaml \
    | kubectl annotate -f - --local -o yaml \
        "openldap.platform/pwd-changed-time=${stamp}" \
    | kubectl label -f - --local -o yaml \
        "app.kubernetes.io/managed-by=Helm" \
        "app.kubernetes.io/component=user-credentials" \
        "app.kubernetes.io/part-of=openldap-platform" \
        "openldap.platform/release=${RELEASE_NAME}" \
        "openldap.platform/user=${uid}" \
    | kubectl apply -f - >/dev/null
}

secret_password_delete() {
  kubectl -n "${RELEASE_NAMESPACE}" delete secret "$(secret_name_for_user "$1")" \
    --ignore-not-found=true >/dev/null
}

gen_password() { openssl rand -base64 24 | tr -d '=/+' | head -c 24; }

# -------------------------------------------------------------------------
# cn=config bind - required by acls / tree-grants / overlays / acl-lint.
# Sourced only when the caller sets `NEED_CONFIG_BIND=1` to keep other
# scripts on the plain admin bind.
# -------------------------------------------------------------------------
load_config_bind() {
  [ -f /secrets/config-admin-password ] \
    || DIE "config admin password missing at /secrets/config-admin-password"
  LDAP_CONFIG_BIND_DN="${LDAP_CONFIG_BIND_DN:-cn=adminconfig,cn=config}"
  export LDAP_CONFIG_BIND_DN
  if [ "${PASSWORD_FILES:-false}" = "true" ]; then
    LDAP_CONFIG_BIND_PW_FILE=/secrets/config-admin-password
    export LDAP_CONFIG_BIND_PW_FILE
  else
    LDAP_CONFIG_BIND_PW="$(cat /secrets/config-admin-password)"
    export LDAP_CONFIG_BIND_PW
  fi
}

# -------------------------------------------------------------------------
# OU drift policy (values `onOuChange`) - what to do when an entry is not
# in the OU its values declare. Only users.sh / groups.sh act on it; the
# validation lives here so an unusable value fails on the first Job rather
# than on the first drifting entry.
# -------------------------------------------------------------------------
: "${ON_OU_CHANGE:=warn}"
case "$ON_OU_CHANGE" in
  warn|move|fail) ;;
  *) DIE "onOuChange=${ON_OU_CHANGE}: expected warn|move|fail" ;;
esac

# `cn=x,ou=users,dc=example,dc=org` -> `ou=users`, and -> `cn=x`.
#
# Both refuse a DN whose RDN carries an escaped separator (`cn=a\,b`):
# cutting on the first comma would then split inside the name, and the
# caller has no safe way to rebuild the DN. Such an entry is left alone
# rather than moved to a truncated RDN.
dn_parent_ou() {
  case "${1%%,*}" in *\\*) return 1 ;; esac
  _p=${1#*,}
  printf '%s' "${_p%",${LDAP_BASE_DN}"}"
}

dn_rdn() {
  case "${1%%,*}" in *\\*) return 1 ;; esac
  printf '%s' "${1%%,*}"
}

# -------------------------------------------------------------------------
# Chart state ConfigMap helpers - used by acls / tree-grants / overlays
# to track their previously-applied set across upgrades. Data key = phase
# name (acls | tree-grants | overlays).
# -------------------------------------------------------------------------
STATE_CM_NAME="${RELEASE_FULLNAME}-sync-state"

state_get() {
  # $1 = data key; prints the JSON body verbatim (or "[]" when absent).
  # Deliberately NOT `read -r`: the stored body can span several lines and
  # `read` returns only the first one ("["), which every drift filter below
  # then fails to parse - and their `|| echo []` fallback turns that into a
  # silent "nothing was ever applied", so removals are never revoked.
  _body=$(kubectl -n "${RELEASE_NAMESPACE}" get configmap "${STATE_CM_NAME}" \
    -o "jsonpath={.data.$1}" 2>/dev/null || true)
  [ -n "${_body}" ] || _body="[]"
  printf '%s' "${_body}"
}

state_put() {
  # $1 = data key, $2 = path to new JSON file
  if ! kubectl -n "${RELEASE_NAMESPACE}" get configmap "${STATE_CM_NAME}" >/dev/null 2>&1; then
    kubectl -n "${RELEASE_NAMESPACE}" create configmap "${STATE_CM_NAME}" \
      --from-literal="$1=$(cat "$2")" >/dev/null
    kubectl -n "${RELEASE_NAMESPACE}" label configmap "${STATE_CM_NAME}" \
      --overwrite \
      "app.kubernetes.io/managed-by=Helm" \
      "app.kubernetes.io/component=sync-state" \
      "app.kubernetes.io/part-of=openldap-platform" \
      "openldap.platform/release=${RELEASE_NAME}" >/dev/null
  else
    kubectl -n "${RELEASE_NAMESPACE}" patch configmap "${STATE_CM_NAME}" \
      --type=merge -p "$(jq -n --arg k "$1" --rawfile v "$2" '{data:{($k):$v}}')" >/dev/null
  fi
}

  # ---------------------------------------------------------------------------
  # ppolicy.sh - reconciles ppolicy templates under ou=policies.
  # ---------------------------------------------------------------------------
{{- end -}}
