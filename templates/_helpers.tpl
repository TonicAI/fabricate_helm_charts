{{- define "fabricate.delayedBindingStorageClassEffective" -}}
{{- $del := (.Values.volumesProvisioning | default dict).delayedBindingStorageClass | default dict -}}
{{- $provisioner := trim (toString (default "" $del.provisioner)) -}}
{{- if not (and (default false $del.enabled) (ne $provisioner "")) -}}
{{- "" -}}
{{- else -}}
{{- $n := trim (toString (default "" $del.name)) -}}
{{- if ne $n "" -}}{{- $n | trunc 63 | trimSuffix "-" -}}{{- else -}}{{- printf "%s-wffc" (include "fabricate.prefix" $) | trunc 63 | trimSuffix "-" -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.name" -}}
{{- default .Chart.Name .Values.app | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.prefix" -}}
{{- $base := include "fabricate.name" . -}}
{{- $env := (default "" .Values.environment) | trim -}}
{{- if ne $env "" -}}
{{- printf "%s-%s" $base $env | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $base -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.workloadName" -}}
{{- $root := index . "root" -}}
{{- $suffix := index . "suffix" | required "fabricate.workloadName: missing suffix" -}}
{{- printf "%s-%s" (include "fabricate.prefix" $root) $suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.labels" -}}
helm.sh/chart: {{ include "fabricate.chart" . }}
app.kubernetes.io/name: {{ include "fabricate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "fabricate.name" . }}
{{- with .Values.environment }}
fabricate.ai/environment: {{ . | quote }}
{{- end }}
{{- with .Values.allLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- /* Merged metadata.annotations: values.allAnnotations on every resource, plus per-resource extras (extras win). Pass dict "root" . "extra" <map>. */ -}}
{{- define "fabricate.annotations" -}}
{{- $m := merge (deepCopy (.extra | default dict)) (deepCopy (.root.Values.allAnnotations | default dict)) -}}
{{- if $m -}}
annotations:
{{- toYaml $m | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "fabricate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fabricate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* 1 when chart NetworkPolicies should render; honors bool false and strings false/0/no from --set */ -}}
{{- define "fabricate.networkPolicyOn" -}}
{{- $nc := .Values.networkPolicy | default dict -}}
{{- if hasKey $nc "enabled" -}}
{{- $s := lower (trim (toString $nc.enabled)) -}}
{{- if or (eq $s "false") (eq $s "0") (eq $s "no") -}}
{{- else -}}1{{- end -}}
{{- else -}}1{{- end -}}
{{- end -}}

{{- /* Chart-level default when services.<name>.pullPolicy is unset (see fabricate.serviceImagePullPolicy). */ -}}
{{- define "fabricate.imagePullPolicy" -}}
{{- default "IfNotPresent" .Values.imagePullPolicy -}}
{{- end -}}

{{- /* Dict: root (Chart), svc (services.web | worker | …). Order: svc.pullPolicy → .Values.imagePullPolicy → IfNotPresent. */ -}}
{{- define "fabricate.serviceImagePullPolicy" -}}
{{- $root := index . "root" -}}
{{- $svc := index . "svc" | default dict -}}
{{- coalesce (index $svc "pullPolicy") $root.Values.imagePullPolicy "IfNotPresent" -}}
{{- end -}}

{{/* kubernetes.io/dockerconfigjson pull secret: default <fabricate.prefix>-registry (e.g. fabricate-prod-registry). */ -}}
{{- define "fabricate.defaultRegistrySecretName" -}}
{{- printf "%s-registry" (include "fabricate.prefix" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.imagePullSecretName" -}}
{{- $rp := .Values.registry | default dict -}}
{{- $host := trim (default "" (index $rp "host")) -}}
{{- $user := default "" (index $rp "username") -}}
{{- $pass := default "" (index $rp "password") -}}
{{- if and $host $user $pass -}}
{{- include "fabricate.defaultRegistrySecretName" . -}}
{{- else if lookup "v1" "Secret" .Release.Namespace (include "fabricate.defaultRegistrySecretName" .) -}}
{{- /* Secret from an earlier deploy (or created by hand): keep using it without credentials in values. */ -}}
{{- include "fabricate.defaultRegistrySecretName" . -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.imagePodPullSecrets" -}}
{{- with (include "fabricate.imagePullSecretName" . | trim) }}
imagePullSecrets:
  - name: {{ . | quote }}
{{- end }}
{{- end -}}

{{- /* Pods for chart workloads; create: false + empty name → default account. */ -}}
{{- define "fabricate.serviceAccountName" -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- $n := trim (toString (default "" (index $sa "name"))) -}}
{{- if not (default false (index $sa "create")) -}}
{{- if ne $n "" -}}{{- $n -}}{{- else -}}default{{- end -}}
{{- else -}}
{{- if ne $n "" -}}{{- $n -}}{{- else -}}{{- printf "%s-sa" (include "fabricate.prefix" .) | trunc 63 | trimSuffix "-" -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.workloadServiceAccountName" -}}
serviceAccountName: {{ include "fabricate.serviceAccountName" . | quote }}
{{- end -}}

{{- /* Optional per-service nodeSelector; pass dict "svc" (.Values.services.web etc.). */ -}}
{{- define "fabricate.serviceNodeSelector" -}}
{{- $svc := index . "svc" -}}
{{- $sel := index $svc "nodeSelector" | default dict -}}
{{- if gt (len $sel) 0 }}
nodeSelector:
{{- toYaml $sel | nindent 2 }}
{{- end }}
{{- end -}}

{{- /*
  Co-location of web/worker on one node (values.podColocation.enabled; on unless set false). They share the ReadWriteOnce EBS
  claim (data), which can only be attached to a single node; this keeps all pods together so a node
  replacement moves them (and re-attaches the volumes) as a group instead of causing Multi-Attach errors.
*/ -}}
{{- define "fabricate.podColocation" -}}
{{- $c := .Values.podColocation | default dict -}}
{{- if or (not (hasKey $c "enabled")) $c.enabled }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "fabricate.selectorLabels" . | nindent 12 }}
          matchExpressions:
            - key: app.kubernetes.io/component
              operator: In
              values: [web, worker]
{{- end }}
{{- end -}}

{{- /* Optional pod tolerations: values.tolerations (all workloads); match node pool taints. */ -}}
{{- define "fabricate.podTolerations" -}}
{{- $tol := .Values.tolerations | default list -}}
{{- if not (kindIs "slice" $tol) }}{{- $tol = list }}{{- end }}
{{- if gt (len $tol) 0 }}
tolerations:
{{- toYaml $tol | nindent 2 }}
{{- end }}
{{- end -}}

{{- /*
  Deployment spec.strategy for web / worker / sidecar from .Values.deployStrategy only (RollingUpdate | Recreate).
*/ -}}
{{- define "fabricate.deploymentStrategy" -}}
{{- $typ := trim (toString (default "Recreate" .Values.deployStrategy)) -}}
{{- if not (or (eq $typ "RollingUpdate") (eq $typ "Recreate")) -}}
{{- fail (printf "deployStrategy must be RollingUpdate or Recreate; got %q" $typ) -}}
{{- end -}}
strategy:
  type: {{ $typ }}
{{- if eq $typ "RollingUpdate" }}
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
{{- end }}
{{- end }}

{{- /*
  RWO PVC mounts are root-owned by default; fsGroup lets non-root app UIDs write data.
  seLinuxLevel: on SELinux nodes (Bottlerocket / EKS Auto Mode) every pod gets a random MCS category pair and the shared
  volumes are labeled for the first pod that mounts them, so web and worker would be denied each other's files.
  Giving both pods the same level (e.g. "s0:c100,c200") lets them share the volumes.
*/ -}}
{{- define "fabricate.sharedAppVolumesSecurityContext" -}}
securityContext:
  fsGroup: {{ int (default 1000 (index (.Values.volumesSecurity | default dict) "fsGroup")) }}
  fsGroupChangePolicy: Always
  {{- with (index (.Values.volumesSecurity | default dict) "seLinuxLevel") }}
  seLinuxOptions:
    level: {{ . | quote }}
  {{- end }}
{{- end -}}
{{- /*
  Per-service strategy: same type as deployStrategy, rolling parameters from services.<name>.rollingUpdate
  (maxSurge default 0, maxUnavailable default 1). maxSurge 1 / maxUnavailable 0 starts the new pod before the old one
  stops (needs the pods co-located on one node when volumes are ReadWriteOnce).
*/ -}}
{{- define "fabricate.deploymentStrategyFor" -}}
{{- $root := index . "root" -}}
{{- $svc := index . "svc" | default dict -}}
{{- $typ := trim (toString (default "Recreate" $root.Values.deployStrategy)) -}}
{{- if not (or (eq $typ "RollingUpdate") (eq $typ "Recreate")) -}}
{{- fail (printf "deployStrategy must be RollingUpdate or Recreate; got %q" $typ) -}}
{{- end -}}
{{- $ru := index $svc "rollingUpdate" | default dict -}}
{{- $surge := 0 -}}
{{- if hasKey $ru "maxSurge" }}{{- $surge = index $ru "maxSurge" }}{{- end -}}
{{- $unavail := 1 -}}
{{- if hasKey $ru "maxUnavailable" }}{{- $unavail = index $ru "maxUnavailable" }}{{- end -}}
strategy:
  type: {{ $typ }}
{{- if eq $typ "RollingUpdate" }}
  rollingUpdate:
    maxSurge: {{ $surge }}
    maxUnavailable: {{ $unavail }}
{{- end }}
{{- end -}}

{{- /*
  Container securityContext of the Fabricate app containers (web, worker): no privilege escalation, plus SYS_PTRACE
  when volumesSecurity.sysptrace is on. The image runs as a named non-root user, which the kubelet cannot verify, so
  runAsNonRoot is only enforced when appSecurityContext.runAsUser gives the numeric UID of that user.
*/ -}}
{{- define "fabricate.appContainerPtraceCapability" -}}
{{- $sc := .Values.appSecurityContext | default dict -}}
securityContext:
  allowPrivilegeEscalation: {{ if hasKey $sc "allowPrivilegeEscalation" }}{{ index $sc "allowPrivilegeEscalation" }}{{ else }}false{{ end }}
  {{- with index $sc "runAsUser" }}
  runAsNonRoot: true
  runAsUser: {{ int . }}
  {{- end }}
  {{- if default false (index (.Values.volumesSecurity | default dict) "sysptrace") }}
  capabilities:
    add:
      - SYS_PTRACE
  {{- end }}
{{- end -}}

{{- /*
  securityContext of the other containers (sidecar, PostgreSQL, Redis): no privilege escalation. They are not forced
  to run as non-root: the official PostgreSQL and Redis images start as root and drop to their own user themselves.
*/ -}}
{{- define "fabricate.containerSecurityContext" -}}
{{- $sc := .Values.appSecurityContext | default dict -}}
securityContext:
  allowPrivilegeEscalation: {{ if hasKey $sc "allowPrivilegeEscalation" }}{{ index $sc "allowPrivilegeEscalation" }}{{ else }}false{{ end }}
{{- end -}}

{{- /*
  Sidecar container securityContext: no privilege escalation always. The image runs as the named user "pdfuser" (not a
  numeric UID), so the kubelet cannot verify it is non-root: runAsNonRoot is only enforced when services.sidecar.runAsUser
  gives the numeric UID of that user.
*/ -}}
{{- define "fabricate.sidecarSecurityContext" -}}
{{- $sc := .Values.appSecurityContext | default dict -}}
{{- $svc := .Values.services.sidecar | default dict -}}
securityContext:
  allowPrivilegeEscalation: {{ if hasKey $sc "allowPrivilegeEscalation" }}{{ index $sc "allowPrivilegeEscalation" }}{{ else }}false{{ end }}
  {{- with index $svc "runAsUser" }}
  runAsNonRoot: true
  runAsUser: {{ int . }}
  {{- end }}
{{- end -}}

{{- /* Init containers: optional PVC chown (EKS): a small busybox that makes the mounted volumes writable for the app. */ -}}
{{- define "fabricate.initContainers" -}}
{{- $root := index . "root" -}}
{{- $mounts := index . "mounts" | default list -}}
{{- $svc := index . "svc" | default dict -}}
{{- $sv := $root.Values.volumesSecurity | default dict -}}
{{- $ic := index $sv "initChown" | default dict -}}
{{- $chownEnabled := default false (index $ic "enabled") -}}
{{- if $chownEnabled }}
{{- $uid := int (default 1000 (index $ic "uid")) }}
{{- $gid := int (default 1000 (index $ic "gid")) }}
initContainers:
  - name: fix-volume-perms
    image: {{ default "busybox:1.36" (index $ic "image") | quote }}
    securityContext:
      runAsUser: 0
      allowPrivilegeEscalation: false
      capabilities:
        # the managed EBS CSI driver (ebs.csi.eks.amazonaws.com) does not implement
        # VOLUME_MOUNT_GROUP, so EBS volumes mount with root-owned subdirectories that a non-privileged
        # root process cannot traverse to chown. https://github.com/aws/containers-roadmap/issues/2550
        add: ["DAC_OVERRIDE"]
    command:
      - sh
      - -c
      - >
          {{- range $m := $mounts }}
          chown -R {{ $uid }}:{{ $gid }} {{ $m.path | quote }};
          {{- end }}
    volumeMounts:
      {{- include "fabricate.volumeMounts" (dict "mounts" $mounts) | trim | nindent 6 }}
{{- end }}
{{- end -}}

{{- /*
  Container command for the worker. Optional override: services.worker.command (list); otherwise the default below.
*/ -}}
{{- define "fabricate.workerCommand" -}}
{{- toYaml (default (list "bundle" "exec" "sidekiq" "-e" "production") .command) -}}
{{- end -}}

{{- /*
  Container command for in-cluster Redis. Optional override: services.redis.command (list); otherwise the default
  below, which requires REDIS_PASSWORD from the shared env Secret.
*/ -}}
{{- define "fabricate.redisCommand" -}}
{{- toYaml (default (list "sh" "-c" "exec redis-server --requirepass \"$REDIS_PASSWORD\"") .command) -}}
{{- end -}}

{{- /*
  HTTP health check path of the web service (probes, Service backend config, ingress health check on GKE gce /
  Amazon EKS alb). Optional override: services.web.healthCheckPath; default /up. Pass the service dict.
*/ -}}
{{- define "fabricate.webHealthCheckPath" -}}
{{- trim (toString (default "/up" (index (default (dict) .) "healthCheckPath"))) -}}
{{- end -}}

{{- /*
  HTTP path for the PDF sidecar readiness and liveness probes. Optional override: services.sidecar.healthCheckPath;
  default /health. Pass the service dict.
*/ -}}
{{- define "fabricate.sidecarHealthCheckPath" -}}
{{- trim (toString (default "/health" (index (default (dict) .) "healthCheckPath"))) -}}
{{- end -}}

{{- /*
  Web rollout settings, each an optional override under services.web with a built-in default. Pass the service dict.
  Probes use the health check path; a pod is Ready (and the old one stops) only when it serves. preStop sleep keeps
  the old pod serving while the load balancer deregisters it; the grace period must be larger than it.
*/ -}}
{{- /* services.web.probes.enabled; default true. Prints 1 when on. */ -}}
{{- define "fabricate.webProbesEnabled" -}}
{{- $pr := default (dict) (index (default (dict) .) "probes") -}}
{{- if hasKey $pr "enabled" }}{{ if $pr.enabled }}1{{ end }}{{ else }}1{{ end -}}
{{- end -}}

{{- /* services.web.preStopSleepSeconds; default 15, 0 disables the preStop hook. */ -}}
{{- define "fabricate.webPreStopSleepSeconds" -}}
{{- $s := default (dict) . -}}
{{- if hasKey $s "preStopSleepSeconds" }}{{ int $s.preStopSleepSeconds }}{{ else }}15{{ end -}}
{{- end -}}

{{- /* services.web.terminationGracePeriodSeconds; default 60. */ -}}
{{- define "fabricate.webTerminationGracePeriodSeconds" -}}
{{- $s := default (dict) . -}}
{{- if hasKey $s "terminationGracePeriodSeconds" }}{{ int $s.terminationGracePeriodSeconds }}{{ else }}60{{ end -}}
{{- end -}}

{{- /* Deprecated alias — use fabricate.initContainers */ -}}
{{- define "fabricate.initChownVolumes" -}}
{{- include "fabricate.initContainers" . -}}
{{- end -}}

{{- define "fabricate.postgresql.svc" -}}
{{ include "fabricate.workloadName" (dict "root" . "suffix" "postgresql") }}
{{- end -}}

{{- define "fabricate.redis.svc" -}}
{{ include "fabricate.workloadName" (dict "root" . "suffix" "redis") }}
{{- end -}}

{{- define "fabricate.sidecar.svc" -}}
{{ include "fabricate.workloadName" (dict "root" . "suffix" "sidecar") }}
{{- end -}}

{{- /* TCP port the PDF sidecar listens on (services.sidecar.ports.http, default 3100). */ -}}
{{- define "fabricate.sidecar.port" -}}
{{- $sc := default (dict) .Values.services.sidecar -}}
{{- default 3100 (index (default (dict) (index $sc "ports")) "http") -}}
{{- end -}}

{{- define "fabricate.web.svc" -}}
{{ include "fabricate.workloadName" (dict "root" . "suffix" "web") }}
{{- end -}}

{{- /* Same normalization as web-ingress (nginx | gce | alb | custom). */ -}}
{{- define "fabricate.ingressProviderNormalized" -}}
{{- $ing := .Values.ingress | default dict -}}
{{- $p := lower (trim (toString (default "nginx" (index $ing "provider")))) -}}
{{- if or (eq $p "null") (eq $p "") (eq $p "<no value>") -}}
{{- $p = "nginx" -}}
{{- end -}}
{{- $p -}}
{{- end -}}

{{- /* Ingress rule host: ingress.host, else FABRICATE_HOST from services.web.env, else .Values.env */ -}}
{{- define "fabricate.ingressHost" -}}
{{- $ing := .Values.ingress | default dict -}}
{{- $h := trim (toString (default "" (index $ing "host"))) -}}
{{- if or (eq $h "null") (eq $h "<no value>") -}}
{{- $h = "" -}}
{{- end -}}
{{- if eq $h "" -}}
{{- $h = trim (toString (default "" (index (.Values.services.web.env | default dict) "FABRICATE_HOST"))) -}}
{{- end -}}
{{- if eq $h "" -}}
{{- $h = trim (toString (default "" (index (.Values.env | default dict) "FABRICATE_HOST"))) -}}
{{- end -}}
{{- if eq $h "" -}}
{{- $h = trim (include "fabricate.resolvedLbNipHost" .) -}}
{{- end -}}
{{- $h -}}
{{- end -}}

{{- /* Own Ingress status (GCE / ALB / ingress-nginx): <external-ip>.nip.io or AWS hostname */ -}}
{{- define "fabricate.ingressStatusNipHost" -}}
{{- $ingName := include "fabricate.workloadName" (dict "root" . "suffix" "ingress") -}}
{{- $ingObj := lookup "networking.k8s.io/v1" "Ingress" (default "default" .Release.Namespace) $ingName -}}
{{- if $ingObj -}}
{{- $st := default dict $ingObj.status -}}
{{- $lb := default dict (index $st "loadBalancer") -}}
{{- $ings := default list (index $lb "ingress") -}}
{{- if gt (len $ings) 0 -}}
{{- $el := index $ings 0 -}}
{{- $lbip := trim (toString (default "" (index $el "ip"))) -}}
{{- $lbhn := trim (toString (default "" (index $el "hostname"))) -}}
{{- if ne $lbip "" -}}
{{- printf "%s.nip.io" $lbip -}}
{{- else if ne $lbhn "" -}}
{{- $lbhn -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Separately installed ingress-nginx controller Service (namespace/name fixed by upstream chart). */ -}}
{{- define "fabricate.ingressNginxServiceNipHost" -}}
{{- $ingsvc := lookup "v1" "Service" "ingress-nginx" "ingress-nginx-controller" -}}
{{- if $ingsvc -}}
{{- $st := default dict $ingsvc.status -}}
{{- $lb := default dict (index $st "loadBalancer") -}}
{{- $ings := default list (index $lb "ingress") -}}
{{- if gt (len $ings) 0 -}}
{{- $el := index $ings 0 -}}
{{- $lbip := trim (toString (default "" (index $el "ip"))) -}}
{{- $lbhn := trim (toString (default "" (index $el "hostname"))) -}}
{{- if ne $lbip "" -}}
{{- printf "%s.nip.io" $lbip -}}
{{- else if ne $lbhn "" -}}
{{- $lbhn -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* 1 when services.web.enabled is on (honors bool false and strings false/0/no from --set). */ -}}
{{- define "fabricate.webServiceEnabled" -}}
{{- $w := index (.Values.services | default dict) "web" | default dict -}}
{{- if hasKey $w "enabled" -}}
{{- $s := lower (trim (toString $w.enabled)) -}}
{{- if or (eq $s "false") (eq $s "0") (eq $s "no") -}}
{{- else -}}1{{- end -}}
{{- else -}}1{{- end -}}
{{- end -}}

{{- /* 1 when chart Ingress should render (honors bool false and strings false/0/no from --set). */ -}}
{{- define "fabricate.ingressEnabled" -}}
{{- $ing := .Values.ingress | default dict -}}
{{- if hasKey $ing "enabled" -}}
{{- $s := lower (trim (toString $ing.enabled)) -}}
{{- if or (eq $s "false") (eq $s "0") (eq $s "no") -}}
{{- else -}}1{{- end -}}
{{- else -}}1{{- end -}}
{{- end -}}

{{- /* When ingress + web are enabled and FABRICATE_HOST is unset: LB-derived nip.io host */ -}}
{{- define "fabricate.resolvedLbNipHost" -}}
{{- if and (eq (include "fabricate.ingressEnabled" . | trim) "1") (eq (include "fabricate.webServiceEnabled" . | trim) "1") -}}
{{- $fromIng := trim (include "fabricate.ingressStatusNipHost" .) -}}
{{- if ne $fromIng "" -}}
{{- $fromIng -}}
{{- else -}}
{{- trim (include "fabricate.ingressNginxServiceNipHost" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Resolved ingress spec.ingressClassName: explicit ingress.class, else defaults by ingress.provider (nginx|gce|alb). Empty for custom/other. */ -}}

{{- /* True when Ingress values request TLS at the load balancer (K8s TLS secret / cert-manager or GKE ManagedCertificate). */ -}}
{{- define "fabricate.ingressLbHttps" -}}
{{- $ing := .Values.ingress | default dict -}}
{{- if ne (include "fabricate.ingressEnabled" . | trim) "1" -}}
{{- else -}}
{{- $tls := $ing.tls | default dict -}}
{{- $tlsActive := and (default false (index $tls "enabled")) (ne (trim (toString (default "" (index $tls "secretName")))) "") -}}
{{- $gce := $ing.gce | default dict -}}
{{- $mc := $gce.managedCertificate | default dict -}}
{{- $mcActive := and (eq (include "fabricate.ingressProviderNormalized" . | trim) "gce") (default false (index $mc "enabled")) -}}
{{- if or $tlsActive $mcActive -}}1{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.ingressClassResolved" -}}
{{- $ing := .Values.ingress | default dict -}}
{{- $p := lower (trim (toString (default "nginx" (index $ing "provider")))) -}}
{{- if or (eq $p "") (eq $p "null") (eq $p "<no value>") -}}
{{- $p = "nginx" -}}
{{- end -}}
{{- $raw := trim (toString (default "" (index $ing "class"))) -}}
{{- if or (eq $raw "null") (eq $raw "<no value>") -}}
{{- $raw = "" -}}
{{- end -}}
{{- if ne $raw "" -}}
{{- $raw -}}
{{- else if eq $p "gce" -}}
gce
{{- else if eq $p "alb" -}}
alb
{{- else if eq $p "nginx" -}}
nginx
{{- end -}}
{{- end -}}

{{- define "fabricate.secretsBase" -}}
{{- $ns := default "default" .Release.Namespace -}}
{{- $env := default "dev" .Values.environment -}}
{{- printf "%s-secrets-%s-%s" (include "fabricate.name" .) $ns $env | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.infrastructureSecretName" -}}
{{- printf "%s-infrastructure" (include "fabricate.secretsBase" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.runtimeSecretName" -}}
{{- printf "%s-runtime" (include "fabricate.secretsBase" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fabricate.sharedSecretName" -}}
{{- printf "%s-env" (include "fabricate.prefix" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Final stringData map for the app env Secret (.Values.env + services.web/worker env + in-cluster Postgres/Redis).
  Empty strings are skipped so overrides and built-in defaults can apply. Worker env wins over web over global on duplicate keys.
*/ -}}
{{- define "fabricate.mergedAppSecretEnv" -}}
{{- /* Values already in the cluster Secret are kept when the key is empty (or absent) in values, so credentials only
       need to be supplied once. FABRICATE_HOST is excluded: it is re-derived from the Ingress when unset. lookup returns
       nothing offline (helm template) and on first install. */ -}}
{{- $previous := dict -}}
{{- $prevSecret := lookup "v1" "Secret" .Release.Namespace (include "fabricate.sharedSecretName" .) -}}
{{- if $prevSecret -}}
{{- range $k, $v := (default (dict) $prevSecret.data) -}}
{{- if ne $k "FABRICATE_HOST" -}}
{{- $_ := set $previous $k (b64dec $v) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $services := default (dict) .Values.services -}}
{{- $globalEnv := default (dict) .Values.env -}}
{{- $globalFiltered := dict -}}
{{- range $k, $v := $globalEnv -}}
{{- if ne (trim (toString $v)) "" -}}
{{- $_ := set $globalFiltered $k $v -}}
{{- end -}}
{{- end -}}
{{- $defaults := dict
  "FABRICATE_PROTOCOL" "http"
  "FABRICATE_LOG_LEVEL" "warn"
  "FABRICATE_DATA_DIR" "/mnt/fabricate/data"
  "FABRICATE_DB_POOL_SIZE" "50"
  "FABRICATE_MAIL_PORT" "587"
  "FABRICATE_DATABASE_PORT" "5432"
  "FABRICATE_STORAGE_SERVICE" "amazon"
  "FABRICATE_ORGANIZATION_NAME" "My Company"
-}}
{{- /* web/worker reach the PDF sidecar over the cluster network (TCP) by its Service name. */ -}}
{{- if default false (index (default (dict) (index $services "sidecar")) "enabled") -}}
{{- $_ := set $defaults "FABRICATE_PDF_HOST" (include "fabricate.sidecar.svc" .) -}}
{{- $_ := set $defaults "FABRICATE_PDF_PORT" (include "fabricate.sidecar.port" . | toString) -}}
{{- end -}}
{{- $pg := default (dict) (index $services "postgresql") -}}
{{- $redis := default (dict) (index $services "redis") -}}
{{- $pgIn := default false (index $pg "enabled") -}}
{{- $rIn := default false (index $redis "enabled") -}}
{{- $pgEnv := default (dict) (index $pg "env") -}}
{{- $redisEnv := default (dict) (index $redis "env") -}}
{{- $web := default (dict) (index $services "web") -}}
{{- $wports := default (dict) (index $web "ports") -}}
{{- $defaultWebPort := toString (default 3000 (index $wports "http")) -}}
{{- $webEnv := default (dict) (index $web "env") -}}
{{- $webFiltered := dict -}}
{{- range $k, $v := $webEnv -}}
{{- if ne (trim (toString $v)) "" -}}
{{- $_ := set $webFiltered $k $v -}}
{{- end -}}
{{- end -}}
{{- $worker := default (dict) (index $services "worker") -}}
{{- $workerEnv := default (dict) (index $worker "env") -}}
{{- $workerFiltered := dict -}}
{{- range $k, $v := $workerEnv -}}
{{- if ne (trim (toString $v)) "" -}}
{{- $_ := set $workerFiltered $k $v -}}
{{- end -}}
{{- end -}}

{{- $pgUser := trim (toString (default "" (index $pgEnv "POSTGRES_USER"))) -}}
{{- if eq $pgUser "" -}}
{{- $pgUser = trim (toString (default "" (index $globalEnv "FABRICATE_DATABASE_USERNAME"))) -}}
{{- end -}}
{{- if eq $pgUser "" -}}{{- $pgUser = "fabricate" -}}{{- end -}}

{{- $pgDB := trim (toString (default "" (index $pgEnv "POSTGRES_DB"))) -}}
{{- if eq $pgDB "" -}}
{{- $pgDB = trim (toString (default "" (index $globalEnv "FABRICATE_DATABASE_NAME"))) -}}
{{- end -}}
{{- if eq $pgDB "" -}}{{- $pgDB = "fabricate" -}}{{- end -}}

{{- $pgPass := trim (toString (default "" (index $pgEnv "POSTGRES_PASSWORD"))) -}}
{{- if eq $pgPass "" -}}
{{- $pgPass = trim (toString (default "" (index $globalEnv "FABRICATE_DATABASE_PASSWORD"))) -}}
{{- end -}}

{{- $pgPort := default 5432 (index $pgEnv "POSTGRES_PORT") -}}
{{- if and $pgIn (eq $pgPass "") -}}
{{- fail "in-cluster PostgreSQL enabled: set POSTGRES_PASSWORD in services.postgresql.env or FABRICATE_DATABASE_PASSWORD in .Values.env (e.g. Terraform fabricate_env)" -}}
{{- end -}}

{{- $redisPass := trim (toString (default "" (index $redisEnv "REDIS_PASSWORD"))) -}}
{{- if eq $redisPass "" -}}
{{- $redisPass = trim (toString (default "" (index $globalEnv "FABRICATE_REDIS_PASSWORD"))) -}}
{{- end -}}

{{- $redisPort := default 6379 (index $redisEnv "REDIS_PORT") -}}
{{- if and $rIn (eq $redisPass "") -}}
{{- fail "in-cluster Redis enabled: set REDIS_PASSWORD in services.redis.env or FABRICATE_REDIS_PASSWORD in .Values.env (e.g. Terraform fabricate_env)" -}}
{{- end -}}

{{- /* mergeOverwrite: later maps win (plain merge keeps the first value, so defaults would beat user values) */ -}}
{{- $envOut := mergeOverwrite (dict) $previous $defaults $globalFiltered $webFiltered $workerFiltered -}}
{{- if $pgIn }}
{{- $pgHost := include "fabricate.postgresql.svc" . -}}
{{- $pgPortStr := toString $pgPort -}}
{{- $pgDict := dict
    "POSTGRES_USER" $pgUser
    "POSTGRES_DB" $pgDB
    "POSTGRES_PASSWORD" $pgPass
    "POSTGRES_PORT" $pgPortStr
    "FABRICATE_DATABASE_NAME" $pgDB
    "FABRICATE_DATABASE_USERNAME" $pgUser
    "FABRICATE_DATABASE_PASSWORD" $pgPass
    "FABRICATE_DATABASE_HOST" $pgHost
    "FABRICATE_DATABASE_PORT" $pgPortStr
-}}
{{- $envOut = mergeOverwrite $envOut $pgDict -}}
{{- end }}
{{- if $rIn }}
{{- $rHost := include "fabricate.redis.svc" . -}}
{{- $rPortStr := toString $redisPort -}}
{{- $rURL := printf "redis://:%s@%s:%s" ($redisPass | urlquery) $rHost $rPortStr -}}
{{- $rDict := dict
    "REDIS_PASSWORD" $redisPass
    "REDIS_PORT" $rPortStr
    "FABRICATE_REDIS_URL" $rURL
    "FABRICATE_REDIS_PASSWORD" $redisPass
-}}
{{- $envOut = mergeOverwrite $envOut $rDict -}}
{{- end }}
{{- /* When FABRICATE_HOST is unset: <ingress-lb-ip>.nip.io from this release's Ingress (GCE/ALB/nginx) or ingress-nginx Service */ -}}
{{- $ih := trim (toString (default "" (index $envOut "FABRICATE_HOST"))) -}}
{{- if eq $ih "" -}}
{{- $nip := trim (include "fabricate.resolvedLbNipHost" .) -}}
{{- if ne $nip "" -}}
{{- $envOut = set $envOut "FABRICATE_HOST" $nip -}}
{{- end -}}
{{- end -}}
{{- $fp := trim (toString (default "" (index $envOut "FABRICATE_PORT"))) -}}
{{- if eq $fp "" -}}
{{- $envOut = set $envOut "FABRICATE_PORT" $defaultWebPort -}}
{{- end }}
{{- $ing := .Values.ingress | default dict -}}
{{- if and (eq (include "fabricate.ingressLbHttps" . | trim) "1") (not (default false (index $ing "preserveHttpAppUrl"))) -}}
{{- $envOut = set $envOut "FABRICATE_PROTOCOL" "https" -}}
{{- end -}}
{{- toYaml $envOut -}}
{{- end -}}

{{- define "fabricate.envSecretChecksum" -}}
{{- include "fabricate.mergedAppSecretEnv" . | trim | sha256sum -}}
{{- end -}}

{{- define "fabricate.validateRequiredEnv" -}}
{{- $service := index . "service" -}}
{{- $env := default (dict) (index . "env") -}}
{{- range $key := (index . "required") -}}
{{- if not (hasKey $env $key) -}}
{{- fail (printf "merged app env Secret is missing %s (required for %s)" $key $service) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.envList" -}}
{{- $env := default (dict) . -}}
{{- range $key, $val := $env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
{{- end -}}

{{- define "fabricate.volumeMounts" -}}
{{- $mounts := index . "mounts" -}}
{{- range $mount := $mounts }}
- name: {{ required "mount name is required" $mount.name }}
  mountPath: {{ required (printf "mount path is required for %s" $mount.name) $mount.path | quote }}
{{- end }}
{{- end -}}

{{- define "fabricate.podVolumes" -}}
{{- $root := index . "root" -}}
{{- $mounts := index . "mounts" -}}
{{- range $mount := $mounts }}
{{- $mountName := required "mount name is required" $mount.name }}
{{- /* Use key-based PVC naming with app/environment prefix. */}}
{{- $claimName := printf "%s-%s" (include "fabricate.prefix" $root) $mountName | lower | replace "_" "-" | trunc 63 | trimSuffix "-" }}
- name: {{ $mountName }}
  persistentVolumeClaim:
    claimName: {{ $claimName | quote }}
{{- end }}
{{- end -}}

{{- /*
  Optional container resources per service (values: services.<name>).
  cpu / memory may be:
    - maps with min (→ requests) and max (→ limits); empty, 0, or auto (any case) omits that bound
    - scalars (legacy): treated as requests only (min), no limit for that dimension
  Omit the whole resources block when nothing would be set.
*/ -}}
{{- define "fabricate.resQtyActive" -}}
{{- $n := lower (trim (toString .)) -}}
{{- ne (or (eq $n "") (eq $n "0") (eq $n "auto")) true -}}
{{- end -}}
{{- define "fabricate.containerResources" -}}
{{- $svc := index . "svc" | default dict -}}
{{- $co := index $svc "cpu" -}}
{{- $mo := index $svc "memory" -}}
{{- $cmin := "" -}}{{- $cmax := "" -}}
{{- if kindIs "map" $co -}}
{{- $cmin = index $co "min" -}}{{- $cmax = index $co "max" -}}
{{- else -}}
{{- $cmin = $co -}}
{{- end -}}
{{- $mmin := "" -}}{{- $mmax := "" -}}
{{- if kindIs "map" $mo -}}
{{- $mmin = index $mo "min" -}}{{- $mmax = index $mo "max" -}}
{{- else -}}
{{- $mmin = $mo -}}
{{- end -}}
{{- $cminA := include "fabricate.resQtyActive" $cmin | trim | eq "true" -}}
{{- $cmaxA := include "fabricate.resQtyActive" $cmax | trim | eq "true" -}}
{{- $mminA := include "fabricate.resQtyActive" $mmin | trim | eq "true" -}}
{{- $mmaxA := include "fabricate.resQtyActive" $mmax | trim | eq "true" -}}
{{- $hasReq := or $cminA $mminA -}}
{{- $hasLim := or $cmaxA $mmaxA -}}
{{- if or $hasReq $hasLim }}
resources:
  {{- if $hasReq }}
  requests:
    {{- if $cminA }}
    cpu: {{ trim (toString $cmin) | quote }}
    {{- end }}
    {{- if $mminA }}
    memory: {{ trim (toString $mmin) | quote }}
    {{- end }}
  {{- end }}
  {{- if $hasLim }}
  limits:
    {{- if $cmaxA }}
    cpu: {{ trim (toString $cmax) | quote }}
    {{- end }}
    {{- if $mmaxA }}
    memory: {{ trim (toString $mmax) | quote }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "fabricate.webPort" -}}
{{- $svc := .Values.services.web | default (dict) -}}
{{- $env := $svc.env | default (dict) -}}
{{- $fromEnv := index $env "FABRICATE_PORT" | default "" | toString | trim -}}
{{- if ne $fromEnv "" -}}
{{- $fromEnv -}}
{{- else -}}
{{- $ports := $svc.ports | default (dict) -}}
{{- toString (default 3000 (index $ports "http")) -}}
{{- end -}}
{{- end -}}

{{- define "fabricate.postgresql.port" -}}
{{- $svc := .Values.services.postgresql | default (dict) -}}
{{- $env := $svc.env | default (dict) -}}
{{- default 5432 (index $env "POSTGRES_PORT") -}}
{{- end -}}

{{- define "fabricate.redis.port" -}}
{{- $svc := .Values.services.redis | default (dict) -}}
{{- $env := $svc.env | default (dict) -}}
{{- default 6379 (index $env "REDIS_PORT") -}}
{{- end -}}
