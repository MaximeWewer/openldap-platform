# self-service-password

LDAP Tool Box Self Service Password - end-user password change / reset UI.
Config file (config.inc.local.php) rendered from values; binds against
the sibling openldap subchart's Service by default.

Normally installed via the umbrella [`openldap-platform`](../..) with
`--set self-service-password.enabled=true`. Requires an LDAP bind
account - declare it via `openldap.users` (uid: ssp) and point
`self-service-password.ldap.bind.existingSecret` at the auto-generated
Secret `<release>-openldap-user-ssp`.

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| extraConfig | string | `""` |  |
| extraDeploy | list | `[]` |  |
| extraEnv | list | `[]` |  |
| extraInitContainers | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| general.allowedLanguages[0] | string | `"en"` |  |
| general.allowedLanguages[1] | string | `"fr"` |  |
| general.debug | bool | `false` |  |
| general.keyphraseExistingSecret | string | `""` |  |
| general.language | string | `"en"` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"ltbproject/self-service-password"` |  |
| image.tag | string | `"1.8.1"` |  |
| ingress.enabled | bool | `false` |  |
| ingress.gatewayAPI.gatewayClassName | string | `""` |  |
| ingress.gatewayAPI.gatewayName | string | `""` |  |
| ingress.gatewayAPI.gatewayNamespace | string | `""` |  |
| ingress.gatewayAPI.listenerName | string | `"https"` |  |
| ingress.gatewayAPI.port | int | `443` |  |
| ingress.host | string | `""` |  |
| ingress.ingressNginx.annotations | object | `{}` |  |
| ingress.ingressNginx.className | string | `"nginx"` |  |
| ingress.mode | string | `"ingress-nginx"` |  |
| ingress.tls.certManager.enabled | bool | `false` |  |
| ingress.tls.certManager.issuerRef.kind | string | `"ClusterIssuer"` |  |
| ingress.tls.certManager.issuerRef.name | string | `""` |  |
| ingress.tls.enabled | bool | `false` |  |
| ingress.tls.existingSecret | string | `""` |  |
| ldap.baseDN | string | `"dc=example,dc=org"` |  |
| ldap.bind.dn | string | `"cn=ssp,ou=users,dc=example,dc=org"` |  |
| ldap.bind.existingSecret | string | `""` |  |
| ldap.bind.secretKey | string | `"password"` |  |
| ldap.connection | string | `"ldap"` |  |
| ldap.host | string | `""` |  |
| ldap.loginAttribute | string | `"uid"` |  |
| ldap.port | int | `389` |  |
| ldap.tls.caExistingSecret | string | `""` |  |
| ldap.tls.reqcert | string | `"hard"` |  |
| livenessProbe.httpGet.path | string | `"/"` |  |
| livenessProbe.httpGet.port | string | `"http"` |  |
| livenessProbe.initialDelaySeconds | int | `15` |  |
| livenessProbe.periodSeconds | int | `30` |  |
| mail.from | string | `""` |  |
| mail.fromName | string | `""` |  |
| mail.smtpAuth | bool | `false` |  |
| mail.smtpHost | string | `""` |  |
| mail.smtpPasswordExistingSecret | string | `""` |  |
| mail.smtpPasswordKey | string | `"password"` |  |
| mail.smtpPort | int | `587` |  |
| mail.smtpSecure | string | `"tls"` |  |
| mail.smtpUser | string | `""` |  |
| nodeSelector | object | `{}` |  |
| passwordPolicy.diffLastMinChars | int | `2` |  |
| passwordPolicy.hash | string | `"auto"` |  |
| passwordPolicy.maxLength | int | `64` |  |
| passwordPolicy.minDigit | int | `1` |  |
| passwordPolicy.minLength | int | `12` |  |
| passwordPolicy.minLower | int | `1` |  |
| passwordPolicy.minSpecial | int | `1` |  |
| passwordPolicy.minUpper | int | `1` |  |
| passwordPolicy.noReuse | bool | `true` |  |
| passwordPolicy.noSpecialAtEnds | bool | `true` |  |
| passwordPolicy.showPolicy | string | `"always"` |  |
| passwordPolicy.showPolicyPos | string | `"above"` |  |
| passwordPolicy.specialChars | string | `"^a-zA-Z0-9"` |  |
| passwordPolicy.usePwnedPasswords | bool | `false` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| readinessProbe.httpGet.path | string | `"/"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| readinessProbe.initialDelaySeconds | int | `5` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| replicaCount | int | `1` |  |
| resources.limits.cpu | string | `"500m"` |  |
| resources.limits.memory | string | `"512Mi"` |  |
| resources.requests.cpu | string | `"50m"` |  |
| resources.requests.memory | string | `"128Mi"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.add[0] | string | `"CHOWN"` |  |
| securityContext.capabilities.add[1] | string | `"SETUID"` |  |
| securityContext.capabilities.add[2] | string | `"SETGID"` |  |
| securityContext.capabilities.add[3] | string | `"DAC_OVERRIDE"` |  |
| securityContext.capabilities.add[4] | string | `"NET_BIND_SERVICE"` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `false` |  |
| service.annotations | object | `{}` |  |
| service.port | int | `80` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automountServiceAccountToken | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| sidecars | list | `[]` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
| useQuestions | bool | `false` |  |
| useSms | bool | `false` |  |
| useTokens | bool | `false` |  |
