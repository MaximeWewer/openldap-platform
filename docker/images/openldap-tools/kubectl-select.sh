#!/bin/sh
# kubectl launcher: runs the bundled kubectl closest to the API server.
#
# kubectl supports API servers one minor away (version skew policy); the
# image ships releases two minors apart in /usr/local/lib/kubectl. The server
# minor comes from GET /version (readable by any authenticated or anonymous
# client), read once per container and cached.
#
#   KUBECTL_MINOR=34   force a minor (skips the lookup)
set -eu

DIR=/usr/local/lib/kubectl
CACHE="${TMPDIR:-/tmp}/.kubectl-server-minor"

server_minor() {
  [ -n "${KUBECTL_MINOR:-}" ] && { echo "${KUBECTL_MINOR}"; return; }
  [ -s "${CACHE}" ] && { cat "${CACHE}"; return; }
  sa=/var/run/secrets/kubernetes.io/serviceaccount
  host="${KUBERNETES_SERVICE_HOST:-}"
  [ -n "${host}" ] || return 0
  case "${host}" in *:*) host="[${host}]" ;; esac
  auth=""
  [ -r "${sa}/token" ] && auth="Authorization: Bearer $(cat "${sa}/token")"
  minor=$(curl -fsS --max-time 5 --cacert "${sa}/ca.crt" ${auth:+-H "${auth}"} \
            "https://${host}:${KUBERNETES_SERVICE_PORT:-443}/version" 2>/dev/null \
          | jq -r '.minor // empty' 2>/dev/null | tr -dc '0-9') || minor=""
  if [ -n "${minor}" ]; then echo "${minor}" > "${CACHE}" 2>/dev/null || true; fi
  echo "${minor}"
}

want=$(server_minor)
best=""; best_dist=1000; best_minor=0
for bin in "${DIR}"/kubectl-1.*; do
  [ -x "${bin}" ] || continue
  m="${bin##*kubectl-1.}"
  if [ -z "${want}" ]; then
    # No server to ask (e.g. `kubectl --help`): newest bundled release.
    [ "${m}" -gt "${best_minor}" ] && { best="${bin}"; best_minor="${m}"; }
    continue
  fi
  d=$(( m > want ? m - want : want - m ))
  # Closest minor; on a tie the newer client (skew favours client >= server).
  if [ "${d}" -lt "${best_dist}" ] || { [ "${d}" -eq "${best_dist}" ] && [ "${m}" -gt "${best_minor}" ]; }; then
    best="${bin}"; best_dist="${d}"; best_minor="${m}"
  fi
done

[ -n "${best}" ] || { echo "kubectl: no bundled release in ${DIR}" >&2; exit 127; }
if [ -n "${want}" ] && [ "${best_dist}" -gt 1 ]; then
  echo "kubectl: API server 1.${want} is outside the supported skew of the bundled releases (closest: 1.${best_minor})" >&2
fi
exec "${best}" "$@"
