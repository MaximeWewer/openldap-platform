{{- define "ssp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ssp.fullname" -}}
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

{{- define "ssp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ssp.labels" -}}
helm.sh/chart: {{ include "ssp.chart" . }}
{{ include "ssp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openldap-platform
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "ssp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ssp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ssp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ssp.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
LDAP host. Defaults to `<release>-openldap.<ns>.svc.cluster.local`.
*/}}
{{- define "ssp.ldapHost" -}}
{{- if .Values.ldap.host -}}
{{- .Values.ldap.host -}}
{{- else -}}
{{- printf "%s-openldap.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/*
LDAP URL used inside config.inc.local.php (scheme:// + host + port).
*/}}
{{- define "ssp.ldapUrl" -}}
{{- $scheme := ternary "ldaps" "ldap" (eq .Values.ldap.connection "ldaps") -}}
{{- printf "%s://%s:%d" $scheme (include "ssp.ldapHost" .) (int .Values.ldap.port) -}}
{{- end -}}

{{/*
Keyphrase Secret name.
*/}}
{{- define "ssp.keyphraseSecretName" -}}
{{- if .Values.general.keyphraseExistingSecret -}}
{{- .Values.general.keyphraseExistingSecret -}}
{{- else -}}
{{- printf "%s-keyphrase" (include "ssp.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
persistedValue - same lookup+fallback pattern as elsewhere.
*/}}
{{- define "ssp.persistedValue" -}}
{{- $ctx := .context -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace .secretName -}}
{{- if and $existing (index $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (default 32 .len) -}}
{{- end -}}
{{- end -}}
