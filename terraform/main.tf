locals {
  # False only on AWS with enable_alb = false: Terraform then does not set up or wait for a load balancer; the Ingress
  # and its controller come from your values.yaml (ingress.*) and fabricate_ingress instead.
  use_ingress = var.cloud != "aws" || var.enable_alb

  # Chart naming prefix <app>-<environment>; everything below that must match the chart derives from it.
  name_prefix = "${var.fabricate_app}-${var.fabricate_environment}"
}

module "cluster" {
  source = "./${var.cloud}"

  project_id     = var.project_id
  region         = var.region
  cluster        = var.cluster
  helm_namespace = var.helm_namespace
  helm_release   = var.helm_release
  tags           = var.tags
  name_prefix    = local.name_prefix
  vpc_id         = var.vpc_id
  vpc_subnet_ids = var.vpc_subnet_ids
  # AWS HTTPS listener: enable flag and certificate (empty = self-signed)
  enable_https   = var.enable_https
  https_cert_arn = var.https_cert_arn
  # AWS: ALB as ingress controller, managed RDS / ElastiCache (false = run in the cluster) and Bedrock as the AI provider.
  enable_alb         = var.enable_alb
  enable_rds         = var.enable_rds
  enable_elasticache = var.enable_elasticache
  enable_bedrock     = var.enable_bedrock
  # AWS SES: enable flag and the sender address to verify (also FABRICATE_MAIL_FROM).
  enable_ses        = var.enable_ses
  ses_email         = var.ses_email
  database_password = random_password.fabricate_database_password.result
  redis_password    = random_password.fabricate_redis_password.result
}

# Helm/Kubernetes provider credentials come from module.cluster outputs (managed GKE/EKS).
# Avoid data.google_container_cluster here: it only works if the cluster already exists in GCP,
# so initial apply fails with "cluster not found" before google_container_cluster.primary is created.
#
# Auth is either a static token (GCP) or an exec credential command re-run on every connection (AWS, where tokens
# expire after ~15 minutes); the cloud module sets exactly one of them and leaves the other null.
locals {
  k8s_host  = module.cluster.host
  k8s_ca    = module.cluster.ca_certificate
  k8s_token = module.cluster.token
  k8s_exec  = module.cluster.exec == null ? [] : [module.cluster.exec]
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca
  token                  = local.k8s_token

  dynamic "exec" {
    for_each = local.k8s_exec
    content {
      api_version = exec.value.api_version
      command     = exec.value.command
      args        = exec.value.args
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca
    token                  = local.k8s_token

    dynamic "exec" {
      for_each = local.k8s_exec
      content {
        api_version = exec.value.api_version
        command     = exec.value.command
        args        = exec.value.args
      }
    }
  }
}

resource "random_password" "fabricate_secret_key_base" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "fabricate_database_password" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "fabricate_redis_password" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# Terraform generates random passwords and secrets for Fabricate on first run.
# var.fabricate_env allows overriding generated secrets when needed (e.g. external DB).
locals {
  fabricate_env = merge(
    {
      SECRET_KEY_BASE             = random_password.fabricate_secret_key_base.result
      FABRICATE_DATABASE_PASSWORD = random_password.fabricate_database_password.result
      FABRICATE_REDIS_PASSWORD    = random_password.fabricate_redis_password.result
    },
    module.cluster.helm_env,
    var.fabricate_env,
  )

  # Sets helm chart ingress.provider and ingress.class based on used cloud provider
  fabricate_ingress_providers = {
    gcp = { provider = "gce", class = "gce" }
    aws = {
      provider = "alb"
      class    = "alb"
      # Faster target registration/removal so a new pod gets traffic quickly and the old one drains quickly.
      annotations = {
        "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "10"
        "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
        "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "2"
        "alb.ingress.kubernetes.io/target-group-attributes"      = "deregistration_delay.timeout_seconds=30"
      }
    }
  }
  # Annotations: cloud defaults, then the module's (ALB listeners), then fabricate_ingress.annotations (user wins).
  fabricate_ingress = merge(
    local.fabricate_ingress_providers[var.cloud],
    var.fabricate_ingress,
    {
      annotations = merge(
        try(local.fabricate_ingress_providers[var.cloud].annotations, {}),
        module.cluster.helm_ingress_annotations,
        try(var.fabricate_ingress.annotations, {}),
      )
    }
  )
}

# Values for the Fabricate chart. Used by the Helm release and exposed as the helm_values output so the chart can be
# installed by hand when skip_helm is true.
locals {
  helm_values = merge(
    {
      app            = var.fabricate_app
      environment    = var.fabricate_environment
      env            = local.fabricate_env
      ingress        = merge(var.fabricate_ingress, { for k, v in local.fabricate_ingress : k => v if local.use_ingress })
      serviceAccount = module.cluster.helm_service_account
    },
    module.cluster.helm_volumes_security,
    module.cluster.helm_extra_values,
  )
}

moved {
  from = helm_release.fabricate
  to   = helm_release.fabricate[0]
}

resource "helm_release" "fabricate" {
  count = var.skip_helm ? 0 : 1

  name             = var.helm_release
  namespace        = var.helm_namespace
  create_namespace = true

  chart   = "../${path.module}/"
  timeout = var.helm_timeout
  # Readiness is checked by terraform_data.verify_rollout, which reports why pods are stuck instead of timing out.
  wait = false

  replace         = true
  cleanup_on_fail = true

  # The Helm provider does not notice edits to a local chart; this hash of the chart files changes the release (and
  # triggers an upgrade) whenever Chart.yaml, values.yaml or any template changes. The chart ignores the value.
  set {
    name  = "chartChecksum"
    value = sha1(join("", [for f in concat(["Chart.yaml", "values.yaml"], sort([for t in fileset("${path.module}/../templates", "*") : "templates/${t}"])) : filesha1("${path.module}/../${f}")]))
  }

  # Fluent Bit goes first so logs are already being collected if this release fails.
  depends_on = [module.cluster, helm_release.log_collector, data.external.recover_pending_releases]

  # Chart: values.env → Secret; ingress from var.cloud + var.fabricate_ingress. app + environment → fabricate.prefix
  # (<app>-<environment>); changing only fabricate_env does not rename workloads or PVCs.
  values = [yamlencode(local.helm_values)]
}

# Fluent Bit ships pod logs to CloudWatch Logs (AWS only; module.cluster.log_collector is null elsewhere).
# Installed before the Fabricate release so logs are collected even if that release fails. On Auto Mode the DaemonSet
# has no pods until Fabricate's pods cause the first node to be provisioned; it then schedules onto it automatically.
resource "helm_release" "log_collector" {
  count = !var.skip_helm && module.cluster.log_collector != null ? 1 : 0

  name             = "aws-for-fluent-bit"
  namespace        = module.cluster.log_collector.namespace
  create_namespace = true

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  timeout    = var.helm_timeout
  wait       = false

  depends_on = [module.cluster, data.external.recover_pending_releases]

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = module.cluster.log_collector.service_account
        annotations = {
          "eks.amazonaws.com/role-arn" = module.cluster.log_collector.role_arn
        }
      }
      cloudWatchLogs = {
        enabled         = true
        region          = module.cluster.log_collector.region
        logGroupName    = module.cluster.log_collector.log_group
        autoCreateGroup = false
      }
      firehose      = { enabled = false }
      kinesis       = { enabled = false }
      elasticsearch = { enabled = false }
      tolerations   = [{ operator = "Exists" }]
    })
  ]
}

# Wait for the cloud load balancer behind the Ingress (ALB on AWS, GCE L7 on GCP) so its address is available as a
# Terraform output. Does not fail the apply on timeout; the output is then null (check `kubectl get ingress -n <ns>`).
locals {
  # Chart ingress name: <app>-<environment>-ingress.
  ingress_name = "${local.name_prefix}-ingress"
}

# Shell helpers for the local-exec steps below: `k` is kubectl against this cluster. KUBE_EXEC (AWS) is re-run per call
# because EKS tokens expire; otherwise the static KUBE_TOKEN is used.
locals {
  kube_shell = <<-EOT
    set -u
    ca="$(mktemp)"; trap 'rm -f "$ca"' EXIT
    printf '%s' "$KUBE_CA" > "$ca"
    token() {
      if [ -n "$KUBE_EXEC" ]; then $KUBE_EXEC | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p'; else printf '%s' "$KUBE_TOKEN"; fi
    }
    k() { kubectl --server "$KUBE_HOST" --certificate-authority "$ca" --token "$(token)" "$@"; }
  EOT

  kube_shell_env = {
    KUBE_HOST  = local.k8s_host
    KUBE_CA    = local.k8s_ca
    KUBE_TOKEN = local.k8s_token != null ? local.k8s_token : ""
    KUBE_EXEC  = join(" ", flatten([for e in local.k8s_exec : concat([e.command], e.args)]))
  }

  # Helm releases (<namespace>/<name>) that must install and become ready: Fabricate and, on AWS, Fluent Bit.
  helm_releases = compact([
    "${var.helm_namespace}/${var.helm_release}",
    try("${module.cluster.log_collector.namespace}/aws-for-fluent-bit", ""),
  ])
}

# An interrupted apply can leave a Helm release record stuck in pending-install/upgrade/rollback, and Helm then refuses
# every install with "cannot re-use a name that is still in use". Runs on each plan/apply, before the releases, and
# deletes only those stale release records (Helm release Secrets, not workloads or volumes; the next install adopts
# the existing resources). A data source, so a normal plan stays empty.
data "external" "recover_pending_releases" {
  count = var.skip_helm ? 0 : 1

  program = ["bash", "-c", <<-EOT
    in="$(cat)"; get() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" <<< "$in"; }
    export KUBE_HOST="$(get host)" KUBE_TOKEN="$(get token)" KUBE_EXEC="$(get exec)" KUBE_CA="$(get ca | base64 -d)"
    ${local.kube_shell}
    for r in $(get releases); do
      k delete secret -n "$${r%%/*}" -l "owner=helm,name=$${r##*/},status in (pending-install,pending-upgrade,pending-rollback)" >&2 || true
    done
    echo '{}'
  EOT
  ]

  query = {
    host     = local.k8s_host
    ca       = base64encode(local.k8s_ca)
    token    = local.kube_shell_env.KUBE_TOKEN
    exec     = local.kube_shell_env.KUBE_EXEC
    releases = join(" ", local.helm_releases)
  }
}

# The Helm releases use wait = false, because Helm's own wait only reports "timed out waiting for the condition" after
# the full timeout and never says why. This waits for every workload to roll out (kubectl rollout status stops at the
# Deployment's progress deadline) and, on failure, prints the pods and warning events (image pull errors, scheduling,
# failed mounts, ...) so the cause is in the Terraform output.
resource "terraform_data" "verify_rollout" {
  count = var.skip_helm ? 0 : 1

  triggers_replace = [helm_release.fabricate[0].version, helm_release.fabricate[0].metadata[0].revision]

  depends_on = [helm_release.log_collector]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      ${local.kube_shell}
      deadline=$(( $(date +%s) + TIMEOUT ))
      for ns in $NAMESPACES; do
        for w in $(k get deploy,statefulset,daemonset -n "$ns" -o name); do
          left=$(( deadline - $(date +%s) )); [ "$left" -lt 1 ] && left=1
          k rollout status "$w" -n "$ns" --timeout="$${left}s" && continue
          echo "ERROR: $w in namespace $ns did not become ready" >&2
          k get pods -n "$ns" -o wide >&2
          k get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp | tail -15 >&2
          exit 1
        done
      done
    EOT
    environment = merge(local.kube_shell_env, {
      NAMESPACES = join(" ", distinct([for r in local.helm_releases : split("/", r)[0]]))
      TIMEOUT    = tostring(var.helm_timeout)
    })
  }
}

resource "terraform_data" "wait_for_ingress" {
  count = var.skip_helm || !local.use_ingress ? 0 : 1

  triggers_replace = [helm_release.fabricate[0].version, helm_release.fabricate[0].metadata[0].revision]

  depends_on = [terraform_data.verify_rollout]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      ${local.kube_shell}
      deadline=$(( $(date +%s) + WAIT_SECONDS ))
      echo "Waiting for the load balancer of ingress $NS/$ING (up to $${WAIT_SECONDS}s)..."
      while [ "$(date +%s)" -lt "$deadline" ]; do
        addr="$(k get ingress "$ING" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [ -n "$addr" ]; then echo "Load balancer ready: $addr"; exit 0; fi
        sleep 10
      done
      echo "WARNING: load balancer not ready after $${WAIT_SECONDS}s; continuing." >&2
    EOT
    environment = merge(local.kube_shell_env, {
      NS           = var.helm_namespace
      ING          = local.ingress_name
      WAIT_SECONDS = tostring(var.wait_for_ingress_timeout)
    })
  }
}

data "kubernetes_ingress_v1" "fabricate" {
  count = var.skip_helm || !local.use_ingress ? 0 : 1

  metadata {
    name      = local.ingress_name
    namespace = var.helm_namespace
  }

  depends_on = [terraform_data.wait_for_ingress]
}
