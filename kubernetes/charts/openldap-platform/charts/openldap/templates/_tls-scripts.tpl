{{/*
TLS scripts shared between the pre-install hook (init Job) and the regular
CronJob (renewal). Body only - the callers wrap it into their own ConfigMaps.

  {{ include "openldap.tlsScript.common" . }}
  {{ include "openldap.tlsScript.init"   . }}
  {{ include "openldap.tlsScript.renew"  . }}

The scripts read every knob from env vars set by the caller Job, so no
context-specific templating happens inside.
*/}}
{{- define "openldap.tlsScript.common" -}}
#!/bin/sh
set -eu
LOG() { printf '[tls] %s\n' "$*"; }
DIE() { printf '[tls] ERROR: %s\n' "$*" >&2; exit 1; }

: "${RELEASE_NAMESPACE:?}"; : "${TLS_SECRET_NAME:?}"
: "${CA_DAYS:?}"; : "${CERT_DAYS:?}"; : "${COMMON_NAME:?}"; : "${DNS_NAMES_JSON:?}"

if ! command -v openssl >/dev/null 2>&1; then
  APK_TRIES=0
  until apk add --no-cache openssl ca-certificates curl jq >/dev/null 2>&1; do
    APK_TRIES=$((APK_TRIES + 1))
    [ "$APK_TRIES" -ge 5 ] && DIE "apk add failed after 5 attempts"
    LOG "apk transient failure, retrying"
    sleep 5
  done
fi
if ! command -v kubectl >/dev/null 2>&1; then
  curl --retry 3 --retry-delay 3 -fsSL \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi

build_san_openssl_ext() {
  SAN=$(printf '%s' "${DNS_NAMES_JSON}" | jq -r 'map("DNS:" + .) | join(",")')
  printf 'subjectAltName=%s\n' "${SAN}"
}

read_secret_key() {
  # kubectl jsonpath needs escaped dots for keys like ca.crt / tls.crt;
  # bracket notation is silently unsupported and returns empty.
  esc=$(printf '%s' "$1" | sed 's/\./\\./g')
  kubectl -n "${RELEASE_NAMESPACE}" get secret "${TLS_SECRET_NAME}" \
    -o "jsonpath={.data.${esc}}" 2>/dev/null | base64 -d
}

put_tls_secret() {
  kubectl -n "${RELEASE_NAMESPACE}" create secret generic "${TLS_SECRET_NAME}" \
    --from-file=ca.crt=/tls/ca.crt \
    --from-file=ca.key=/tls/ca.key \
    --from-file=tls.crt=/tls/tls.crt \
    --from-file=tls.key=/tls/tls.key \
    --dry-run=client -o yaml \
    | kubectl label -f - --local -o yaml \
        "app.kubernetes.io/managed-by=Helm" \
        "app.kubernetes.io/component=tls" \
        "openldap.platform/release=${RELEASE_NAME}" \
    | kubectl apply -f - >/dev/null
}

gen_server_cert() {
  openssl genrsa -out /tls/tls.key 2048
  openssl req -new -key /tls/tls.key -out /tls/tls.csr -subj "/CN=${COMMON_NAME}"
  build_san_openssl_ext > /tls/ext.cnf
  openssl x509 -req -in /tls/tls.csr -CA /tls/ca.crt -CAkey /tls/ca.key \
    -CAcreateserial -out /tls/tls.crt -days "${CERT_DAYS}" -sha256 \
    -extfile /tls/ext.cnf
}

rollout_restart_sts() {
  [ "${ROLLING_RESTART:-false}" = "true" ] || return 0
  LOG "rolling-restart of StatefulSet ${STS_NAME}"
  kubectl -n "${RELEASE_NAMESPACE}" rollout restart "statefulset/${STS_NAME}"
}
{{- end -}}

{{- define "openldap.tlsScript.init" -}}
#!/bin/sh
set -eu
. /scripts/common.sh

mkdir -p /tls
if kubectl -n "${RELEASE_NAMESPACE}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1; then
  LOG "Secret ${TLS_SECRET_NAME} already exists - nothing to do"
  exit 0
fi

LOG "generating self-signed CA (validity ${CA_DAYS} days)"
openssl genrsa -out /tls/ca.key 4096
openssl req -x509 -new -nodes -key /tls/ca.key -sha256 \
  -days "${CA_DAYS}" -out /tls/ca.crt \
  -subj "/CN=${COMMON_NAME}-ca"

LOG "generating server cert (validity ${CERT_DAYS} days, CN=${COMMON_NAME})"
gen_server_cert

LOG "writing Secret ${TLS_SECRET_NAME}"
put_tls_secret
LOG "init done"
{{- end -}}

{{- define "openldap.tlsScript.renew" -}}
#!/bin/sh
set -eu
. /scripts/common.sh

: "${RENEW_THRESHOLD_DAYS:?}"; : "${STS_NAME:?}"

if ! kubectl -n "${RELEASE_NAMESPACE}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1; then
  DIE "Secret ${TLS_SECRET_NAME} missing - run init.sh first"
fi

mkdir -p /tls
read_secret_key ca.crt  > /tls/ca.crt
read_secret_key ca.key  > /tls/ca.key
read_secret_key tls.crt > /tls/tls.crt

# openssl -checkend RETURNS 0 if the cert is valid beyond N seconds,
# 1 if it will expire within N seconds. Portable, no date parsing.
THRESHOLD_SECS=$(( RENEW_THRESHOLD_DAYS * 86400 ))
NEED_RENEW=0

if ! openssl x509 -in /tls/tls.crt -checkend "${THRESHOLD_SECS}" -noout; then
  LOG "server cert expires within ${RENEW_THRESHOLD_DAYS}d - regenerating"
  gen_server_cert
  NEED_RENEW=1
else
  LOG "server cert still valid past ${RENEW_THRESHOLD_DAYS}d"
fi

if ! openssl x509 -in /tls/ca.crt -checkend "${THRESHOLD_SECS}" -noout; then
  LOG "CA expires within ${RENEW_THRESHOLD_DAYS}d - regenerating CA + server cert"
  openssl genrsa -out /tls/ca.key 4096
  openssl req -x509 -new -nodes -key /tls/ca.key -sha256 \
    -days "${CA_DAYS}" -out /tls/ca.crt \
    -subj "/CN=${COMMON_NAME}-ca"
  gen_server_cert
  NEED_RENEW=1
else
  LOG "CA still valid past ${RENEW_THRESHOLD_DAYS}d"
fi

if [ "${NEED_RENEW}" -eq 1 ]; then
  put_tls_secret
  rollout_restart_sts
  LOG "renewal complete"
else
  LOG "nothing to do"
fi
{{- end -}}
