{{- define "phpldapadmin.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "phpldapadmin.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "phpldapadmin.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "phpldapadmin.labels" -}}
helm.sh/chart: {{ include "phpldapadmin.chart" . }}
{{ include "phpldapadmin.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openldap-platform
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "phpldapadmin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "phpldapadmin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "phpldapadmin.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "phpldapadmin.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
LDAP host. Defaults to `<release>-openldap.<ns>.svc.cluster.local` which
matches what the openldap subchart emits when installed alongside.
*/}}
{{- define "phpldapadmin.ldapHost" -}}
{{- if .Values.ldap.host -}}
{{- .Values.ldap.host -}}
{{- else -}}
{{- printf "%s-openldap.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/*
Bind password Secret name - either the user's override or a chart-managed
Secret populated with a persisted random password.
*/}}
{{- define "phpldapadmin.bindSecretName" -}}
{{- if .Values.bind.existingSecret -}}
{{- .Values.bind.existingSecret -}}
{{- else -}}
{{- printf "%s-bind" (include "phpldapadmin.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Persist a random value across upgrades via `lookup`.
    _ := include "phpldapadmin.persistedValue" (dict "context" . "secretName" X "key" Y "prefix" "" "len" 32)
*/}}
{{- define "phpldapadmin.persistedValue" -}}
{{- $ctx := .context -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace .secretName -}}
{{- if and $existing (index $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- printf "%s%s" (default "" .prefix) (randAlphaNum (default 32 .len)) -}}
{{- end -}}
{{- end -}}

{{/*
APP_KEY Secret name.
*/}}
{{- define "phpldapadmin.appKeySecretName" -}}
{{- if .Values.app.keyExistingSecret -}}
{{- .Values.app.keyExistingSecret -}}
{{- else -}}
{{- printf "%s-app-key" (include "phpldapadmin.fullname" .) -}}
{{- end -}}
{{- end -}}
