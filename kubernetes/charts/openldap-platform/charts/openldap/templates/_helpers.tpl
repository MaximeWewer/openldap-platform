{{/*
Expand the name of the chart.
*/}}
{{- define "openldap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name - <release>-<chart> unless the release already
carries the chart name (avoids ldap-openldap when release is "openldap").
*/}}
{{- define "openldap.fullname" -}}
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

{{/*
Chart-name label value.
*/}}
{{- define "openldap.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard label set - recommended labels + Helm meta.
*/}}
{{- define "openldap.labels" -}}
helm.sh/chart: {{ include "openldap.chart" . }}
{{ include "openldap.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openldap-platform
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels - stable subset used in Service selectors and StatefulSet.
*/}}
{{- define "openldap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openldap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "openldap.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "openldap.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Admin Secret name - either an override (existingSecret) or the chart-managed
`<fullname>-admin` Secret. Never write into the user-managed Secret.
*/}}
{{- define "openldap.adminSecretName" -}}
{{- if .Values.admin.existingSecret -}}
{{- .Values.admin.existingSecret -}}
{{- else -}}
{{- printf "%s-admin" (include "openldap.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return an existing password from a lookup, or generate a fresh one. Called
from the Secret template so passwords are stable across `helm upgrade` even
though random funcs re-roll on every render.
    _ := include "openldap.persistedPassword" (dict "context" . "secretName" X "key" Y "len" 32)
*/}}
{{- define "openldap.persistedPassword" -}}
{{- $ctx := .context -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace .secretName -}}
{{- if and $existing (index $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum (default 32 .len) -}}
{{- end -}}
{{- end -}}

{{/*
Headless service DNS name (for peer discovery in HA modes).
*/}}
{{- define "openldap.headlessServiceName" -}}
{{- printf "%s-headless" (include "openldap.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render pod affinity - user-provided `.Values.affinity` wins, otherwise
build from the `podAntiAffinityPreset` + `nodeAffinityPreset` shorthands.
Call as:
    {{ include "openldap.affinity" (dict "context" . "component" "server") }}
*/}}
{{- define "openldap.affinity" -}}
{{- $ctx := .context -}}
{{- if $ctx.Values.affinity -}}
{{- toYaml $ctx.Values.affinity -}}
{{- else -}}
{{- $out := dict -}}

{{- /* Pod anti-affinity by hostname (spread replicas across nodes). */ -}}
{{- with $ctx.Values.podAntiAffinityPreset -}}
{{- $rule := dict "labelSelector" (dict "matchLabels" (dict
    "app.kubernetes.io/name" (include "openldap.name" $ctx)
    "app.kubernetes.io/instance" $ctx.Release.Name
    "app.kubernetes.io/component" $.component
  )) "topologyKey" "kubernetes.io/hostname" -}}
{{- if eq . "hard" -}}
{{- $_ := set $out "podAntiAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (list $rule)) -}}
{{- else if eq . "soft" -}}
{{- $_ := set $out "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" 100 "podAffinityTerm" $rule))) -}}
{{- end -}}
{{- end -}}

{{- /* Node affinity - match a label key + accepted values. */ -}}
{{- $na := $ctx.Values.nodeAffinityPreset -}}
{{- if and $na.type $na.key $na.values -}}
{{- $term := dict "matchExpressions" (list (dict "key" $na.key "operator" "In" "values" $na.values)) -}}
{{- if eq $na.type "hard" -}}
{{- $_ := set $out "nodeAffinity" (dict "requiredDuringSchedulingIgnoredDuringExecution" (dict "nodeSelectorTerms" (list $term))) -}}
{{- else if eq $na.type "soft" -}}
{{- $_ := set $out "nodeAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" 100 "preference" $term))) -}}
{{- end -}}
{{- end -}}

{{- toYaml $out -}}
{{- end -}}
{{- end -}}

{{/*
Bootstrap ConfigMap name - either the user's override or the chart-managed
`<fullname>-bootstrap`.
*/}}
{{- define "openldap.bootstrapConfigMapName" -}}
{{- if .Values.existingBootstrapConfigMap -}}
{{- .Values.existingBootstrapConfigMap -}}
{{- else -}}
{{- printf "%s-bootstrap" (include "openldap.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Read-only StatefulSet + Service names.
*/}}
{{- define "openldap.readonlyFullname" -}}
{{- printf "%s-readonly" (include "openldap.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openldap.readonlyHeadlessServiceName" -}}
{{- printf "%s-readonly-headless" (include "openldap.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Replicator Secret name - either an override (existingSecret) or the chart-
managed `<fullname>-replicator` Secret with a persisted random password.
*/}}
{{- define "openldap.replicatorSecretName" -}}
{{- if .Values.replication.replicator.existingSecret -}}
{{- .Values.replication.replicator.existingSecret -}}
{{- else -}}
{{- printf "%s-replicator" (include "openldap.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
TLS Secret name - depends on the tls.backend:
  provided     -> the user-supplied Secret
  cert-manager -> chart-managed <fullname>-tls (target of the Certificate CR)
  job          -> chart-managed <fullname>-tls (written by the tls-init Job)
Every case exposes the same key layout: ca.crt, tls.crt, tls.key.
*/}}
{{- define "openldap.tlsSecretName" -}}
{{- if eq .Values.tls.backend "provided" -}}
{{- required "tls.provided.secretName is required when tls.backend=provided" .Values.tls.provided.secretName -}}
{{- else -}}
{{- printf "%s-tls" (include "openldap.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Default TLS SAN list (used by both cert-manager Certificate and the tls Job).
Includes:
  <fullname>
  <fullname>.<ns>
  <fullname>.<ns>.svc
  <fullname>.<ns>.svc.cluster.local
  <fullname>-headless.<ns>.svc.cluster.local
  <fullname>-<i>.<fullname>-headless.<ns>.svc.cluster.local  (per replica)
Plus, if ingress.host is set, that host too.
User-provided SANs are appended after the defaults.
*/}}
{{- define "openldap.tlsDNSNames" -}}
{{- $ctx := . -}}
{{- $fn := include "openldap.fullname" $ctx -}}
{{- $ns := $ctx.Release.Namespace -}}
{{- $hs := include "openldap.headlessServiceName" $ctx -}}
{{- $names := list $fn (printf "%s.%s" $fn $ns) (printf "%s.%s.svc" $fn $ns) (printf "%s.%s.svc.cluster.local" $fn $ns) (printf "%s.%s.svc.cluster.local" $hs $ns) -}}
{{- range $i, $_ := until (int $ctx.Values.replicaCount) -}}
{{- $names = append $names (printf "%s-%d.%s.%s.svc.cluster.local" $fn $i $hs $ns) -}}
{{- end -}}
{{- if $ctx.Values.ingress.host -}}
{{- $names = append $names $ctx.Values.ingress.host -}}
{{- end -}}
{{- $extra := list -}}
{{- if eq $ctx.Values.tls.backend "cert-manager" -}}
{{- $extra = $ctx.Values.tls.certManager.dnsNames -}}
{{- else if eq $ctx.Values.tls.backend "job" -}}
{{- $extra = $ctx.Values.tls.job.subjectAltNames -}}
{{- end -}}
{{- range $extra -}}
{{- $names = append $names . -}}
{{- end -}}
{{- toJson (uniq $names) -}}
{{- end -}}

{{/*
Best-effort mail domain derived from directory.suffix. Turns
`dc=example,dc=org` into `example.org` and `dc=corp,dc=example,dc=com`
into `corp.example.com`. Users can override by setting
`.Values.directory.mailDomain`.
*/}}
{{- define "openldap.mailDomain" -}}
{{- if .Values.directory.mailDomain -}}
{{- .Values.directory.mailDomain -}}
{{- else -}}
{{- $parts := list -}}
{{- range (splitList "," .Values.directory.suffix) -}}
{{- $parts = append $parts (trimPrefix "dc=" (trim .)) -}}
{{- end -}}
{{- join "." $parts -}}
{{- end -}}
{{- end -}}
