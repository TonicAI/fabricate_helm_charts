locals {
  # Chart naming prefix <app>-<environment>; everything below that must match the chart derives from it.
  name_prefix = "${var.fabricate_app}-${var.fabricate_environment}"
}

module "cluster" {
  source = "./${var.cloud}"

  project_id          = var.project_id
  region              = var.kube_region
  kube_cluster        = var.kube_cluster
  kube_helm_namespace = var.kube_helm_namespace
  kube_helm_release   = var.kube_helm_release
  tags                = var.tags
  name_prefix         = local.name_prefix
  kube_vpc_id         = var.kube_vpc_id
  kube_subnet_ids     = var.kube_subnet_ids
  database_password   = random_password.fabricate_database_password.result
  redis_password      = random_password.fabricate_redis_password.result
}

# Helm/Kubernetes provider credentials come from module.cluster outputs (managed GKE/EKS).
# Avoid data.google_container_cluster here: it only works if the cluster already exists in GCP,
# so initial apply fails with "cluster not found" before google_container_cluster.primary is created.
locals {
  k8s_host  = module.cluster.host
  k8s_ca    = module.cluster.ca_certificate
  k8s_token = module.cluster.token
}

provider "google" {
  project = var.project_id
  region  = var.kube_region
}

provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca
  token                  = local.k8s_token
}

provider "helm" {
  kubernetes {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca
    token                  = local.k8s_token
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
  fabricate_ingress = merge(
    local.fabricate_ingress_providers[var.cloud],
    var.fabricate_ingress
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
      ingress        = local.fabricate_ingress
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

  name             = var.kube_helm_release
  namespace        = var.kube_helm_namespace
  create_namespace = true

  chart   = "../${path.module}/"
  timeout = var.kube_helm_timeout

  replace         = true
  cleanup_on_fail = true

  # The Helm provider does not notice edits to a local chart; this hash of the chart files changes the release (and
  # triggers an upgrade) whenever Chart.yaml, values.yaml or any template changes. The chart ignores the value.
  set {
    name  = "chartChecksum"
    value = sha1(join("", [for f in concat(["Chart.yaml", "values.yaml"], sort([for t in fileset("${path.module}/../templates", "*") : "templates/${t}"])) : filesha1("${path.module}/../${f}")]))
  }

  depends_on = [module.cluster]

  dynamic "set" {
    for_each = trimspace(var.fabricate_registry_host) != "" ? [trimspace(var.fabricate_registry_host)] : []
    content {
      name  = "registry.host"
      value = set.value
    }
  }

  dynamic "set" {
    for_each = trimspace(var.fabricate_registry_username) != "" ? [trimspace(var.fabricate_registry_username)] : []
    content {
      name  = "registry.username"
      value = set.value
    }
  }

  dynamic "set_sensitive" {
    for_each = trimspace(var.fabricate_registry_password) != "" ? [trimspace(var.fabricate_registry_password)] : []
    content {
      name  = "registry.password"
      value = set_sensitive.value
    }
  }

  # Chart: values.env → Secret; ingress from var.cloud + var.fabricate_ingress. app + environment → fabricate.prefix
  # (<app>-<environment>); changing only fabricate_env does not rename workloads or PVCs.
  values = [yamlencode(local.helm_values)]
}

# Fluent Bit ships pod logs to CloudWatch Logs (AWS only; module.cluster.log_collector is null elsewhere).
# Installed after the Fabricate release so the Auto Mode node exists for its DaemonSet.
resource "helm_release" "log_collector" {
  count = !var.skip_helm && module.cluster.log_collector != null ? 1 : 0

  name             = "aws-for-fluent-bit"
  namespace        = module.cluster.log_collector.namespace
  create_namespace = true

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  timeout    = var.kube_helm_timeout

  depends_on = [helm_release.fabricate]

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

resource "terraform_data" "wait_for_ingress" {
  count = var.skip_helm ? 0 : 1

  triggers_replace = [helm_release.fabricate[0].version, helm_release.fabricate[0].metadata[0].revision]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      ca="$(mktemp)"; trap 'rm -f "$ca"' EXIT
      printf '%s' "$KUBE_CA" > "$ca"
      k() { kubectl --server "$KUBE_HOST" --certificate-authority "$ca" --token "$KUBE_TOKEN" "$@"; }
      deadline=$(( $(date +%s) + WAIT_SECONDS ))
      echo "Waiting for the load balancer of ingress $NS/$ING (up to $${WAIT_SECONDS}s)..."
      while [ "$(date +%s)" -lt "$deadline" ]; do
        addr="$(k get ingress "$ING" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [ -n "$addr" ]; then echo "Load balancer ready: $addr"; exit 0; fi
        sleep 10
      done
      echo "WARNING: load balancer not ready after $${WAIT_SECONDS}s; continuing." >&2
    EOT
    environment = {
      KUBE_HOST    = local.k8s_host
      KUBE_CA      = local.k8s_ca
      KUBE_TOKEN   = local.k8s_token
      NS           = var.kube_helm_namespace
      ING          = local.ingress_name
      WAIT_SECONDS = tostring(var.wait_for_ingress_timeout)
    }
  }
}

data "kubernetes_ingress_v1" "fabricate" {
  count = var.skip_helm ? 0 : 1

  metadata {
    name      = local.ingress_name
    namespace = var.kube_helm_namespace
  }

  depends_on = [terraform_data.wait_for_ingress]
}
