{{- /*
Shared Job spec used by ppolicy / users / groups sync Jobs. Call as:

    {{- include "openldap.syncJob" (dict
          "context" .
          "name"    "ppolicy"     # short role name
          "script"  "ppolicy.sh"  # key in the sync-scripts ConfigMap
          "weight"  "5"           # helm hook order
       ) }}
*/}}
{{- define "openldap.syncJob" -}}
{{- $ctx := .context -}}
{{- $fullName := include "openldap.fullname" $ctx -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $fullName }}-sync-{{ .name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "openldap.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: sync
    openldap.platform/sync-role: {{ .name }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "{{ .weight }}"
    # Keep the Job after success so users can `kubectl logs` it. It gets
    # cleaned up on the next helm upgrade (before-hook-creation), never
    # accumulating more than one instance per role.
    helm.sh/hook-delete-policy: before-hook-creation
    checksum/scripts: {{ include (print $ctx.Template.BasePath "/configmap-sync-scripts.yaml") $ctx | sha256sum }}
    checksum/spec: {{ include (print $ctx.Template.BasePath "/configmap-sync-spec.yaml") $ctx | sha256sum }}
spec:
  # Bounded retries - LDAP not-yet-ready is handled inside common.sh's
  # wait_for_ldap, so a Job failure is a real error and shouldn't loop.
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        {{- include "openldap.selectorLabels" $ctx | nindent 8 }}
        app.kubernetes.io/component: sync
        openldap.platform/sync-role: {{ .name }}
    spec:
      restartPolicy: Never
      serviceAccountName: {{ $fullName }}-sync
      securityContext:
        runAsNonRoot: false                # apk add needs root
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: sync
          image: "{{ $ctx.Values.cli.image.repository }}:{{ $ctx.Values.cli.image.tag }}"
          imagePullPolicy: {{ $ctx.Values.cli.image.pullPolicy }}
          command: ["/bin/sh", "-eu", "/scripts/{{ .script }}"]
          env:
            - name: RELEASE_NAME
              value: {{ $ctx.Release.Name | quote }}
            - name: RELEASE_FULLNAME
              value: {{ $fullName | quote }}
            - name: RELEASE_NAMESPACE
              value: {{ $ctx.Release.Namespace | quote }}
            - name: LDAP_URL
              value: "ldap://{{ $fullName }}.{{ $ctx.Release.Namespace }}.svc.cluster.local:{{ $ctx.Values.service.ldapPort }}"
            - name: LDAP_BASE_DN
              value: {{ $ctx.Values.directory.suffix | quote }}
            - name: LDAP_BIND_DN
              value: {{ $ctx.Values.admin.bindDN | quote }}
            - name: LDAP_USER_OU
              value: "ou=users"
            - name: LDAP_GROUP_OU
              value: "ou=groups"
            - name: LDAP_POLICY_OU
              value: "ou=policies"
            - name: LDAP_MAIL_DOMAIN
              value: {{ include "openldap.mailDomain" $ctx | quote }}
            - name: CLI_VERSION
              value: {{ $ctx.Values.cli.version | quote }}
            - name: CLI_DOWNLOAD_URL
              value: {{ $ctx.Values.cli.downloadUrl | quote }}
            - name: KUBECTL_VERSION
              value: {{ $ctx.Values.cli.kubectlVersion | quote }}
            - name: CLI_SHA256
              value: {{ $ctx.Values.cli.sha256 | quote }}
            - name: KUBECTL_SHA256
              value: {{ $ctx.Values.cli.kubectlSha256 | quote }}
            - name: PASSWORD_FILES
              value: {{ $ctx.Values.cli.passwordFiles | quote }}
            - name: WAIT_TIMEOUT_SECONDS
              value: {{ $ctx.Values.cli.waitForLdap.timeoutSeconds | quote }}
            - name: WAIT_INTERVAL_SECONDS
              value: {{ $ctx.Values.cli.waitForLdap.intervalSeconds | quote }}
            - name: ON_USER_REMOVE
              value: {{ $ctx.Values.onUserRemove | quote }}
            - name: ON_GROUP_REMOVE
              value: {{ $ctx.Values.onGroupRemove | quote }}
          resources:
            {{- toYaml $ctx.Values.cli.resources | nindent 12 }}
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: spec
              mountPath: /spec
              readOnly: true
            - name: admin-secret
              mountPath: /secrets
              readOnly: true
      volumes:
        - name: scripts
          configMap:
            name: {{ $fullName }}-sync-scripts
            defaultMode: 0555
        - name: spec
          configMap:
            name: {{ $fullName }}-sync-spec
        - name: admin-secret
          secret:
            secretName: {{ include "openldap.adminSecretName" $ctx }}
            defaultMode: 0400
{{- end -}}
