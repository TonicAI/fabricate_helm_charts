output "host" {
  value = aws_eks_cluster.this.endpoint
}

output "ca_certificate" {
  value = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
}

output "token" {
  value     = data.aws_eks_cluster_auth.this.token
  sensitive = true
}

output "helm_service_account" {
  value = {
    create = true
    # Must match the service account in the IRSA role's trust policy (local.service_account_name).
    name = local.service_account_name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.fabricate.arn
    }
  }
}

# EKS EBS CSI driver does not implement VOLUME_MOUNT_GROUP; initChown is required
# so that non-root containers can write to freshly provisioned EBS volumes.
output "helm_volumes_security" {
  value = {
    volumesSecurity = {
      initChown = { enabled = true }
      # Bottlerocket (EKS Auto Mode) enforces SELinux: all pods sharing the RWO volumes need the same MCS level.
      seLinuxLevel = "s0:c100,c200"
    }
  }
}

# Same rationale as GCP: several RWO EBS PVCs mounted by sibling Deployments — use WaitForFirstConsumer.
output "helm_extra_values" {
  value = {
    # All three pods share RWO EBS volumes and a local unix socket: keep them on one node so they move together
    # on node replacement.
    podColocation = { enabled = true }

    # EKS Auto Mode objects the chart does not own: a NodePool capped to var.eks_node_count nodes (cpu limit = count x
    # vCPUs per node) and the IngressClass (+ params) its built-in ALB controller needs before creating a load balancer.
    additionalResources = [
      {
        apiVersion = "karpenter.sh/v1"
        kind       = "NodePool"
        metadata   = { name = var.name_prefix }
        spec = {
          template = {
            spec = {
              nodeClassRef = { group = "eks.amazonaws.com", kind = "NodeClass", name = "default" }
              requirements = [
                { key = "kubernetes.io/arch", operator = "In", values = ["arm64"] },
                { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
                { key = "node.kubernetes.io/instance-type", operator = "In", values = [var.eks_instance_type] },
              ]
            }
          }
          limits     = { cpu = tostring(var.eks_node_count * var.eks_node_vcpus) }
          disruption = { consolidationPolicy = "WhenEmpty", consolidateAfter = "1h" }
        }
      },
      {
        apiVersion = "eks.amazonaws.com/v1"
        kind       = "IngressClassParams"
        metadata   = { name = "alb" }
        spec       = { scheme = "internet-facing" }
      },
      {
        apiVersion = "networking.k8s.io/v1"
        kind       = "IngressClass"
        metadata   = { name = "alb" }
        spec = {
          controller = "eks.amazonaws.com/alb"
          parameters = { apiGroup = "eks.amazonaws.com", kind = "IngressClassParams", name = "alb" }
        }
      },
    ]

    # RDS and ElastiCache replace the in-cluster PostgreSQL / Redis. App pods are pinned to one Graviton instance type
    # (Auto Mode provisions it on demand), sized for a single 8 GiB node (t4g.large): requests ~2.5 GiB / 0.7 CPU
    # total (web needs a 4 GiB limit: the app checks the container memory), leaving room for a surge web pod during rolling updates.
    services = {
      postgresql = { enabled = false }
      redis      = { enabled = false }
      web = {
        # New pod must be Ready before the old one stops; co-location keeps both on the node holding the RWO volumes.
        rollingUpdate = { maxSurge = 1, maxUnavailable = 0 }
        nodeSelector  = local.node_selector
        cpu           = { min = "300m", max = "2000m" }
        memory        = { min = "1Gi", max = "4Gi" }
      }
      worker = {
        nodeSelector = local.node_selector
        cpu          = { min = "300m", max = "2000m" }
        memory       = { min = "1Gi", max = "4Gi" }
      }
      sidecar = {
        nodeSelector = local.node_selector
        cpu          = { min = "100m", max = "1000m" }
        memory       = { min = "512Mi", max = "1Gi" }
      }
    }

    volumesProvisioning = {
      delayedBindingStorageClass = {
        enabled              = true
        provisioner          = "ebs.csi.eks.amazonaws.com"
        reclaimPolicy        = "Delete"
        allowVolumeExpansion = true
        parameters = {
          type      = "gp3"
          encrypted = "true"
        }
      }
    }
  }
}

# Connection settings for the managed PostgreSQL / Redis and S3 storage, merged into Helm values.env by the root module.
# Redis uses TLS (rediss://) with an AUTH token.
output "helm_env" {
  value = {
    FABRICATE_DATABASE_HOST     = aws_db_instance.this.address
    FABRICATE_DATABASE_PORT     = tostring(aws_db_instance.this.port)
    FABRICATE_DATABASE_NAME     = local.db_name
    FABRICATE_DATABASE_USERNAME = local.db_username
    FABRICATE_DATABASE_PASSWORD = var.database_password
    # Active Storage on S3 via the IRSA role (no access keys).
    FABRICATE_STORAGE_SERVICE = "amazon"
    FABRICATE_S3_BUCKET       = aws_s3_bucket.storage.bucket
    FABRICATE_AWS_REGION      = var.region
    # Keep concurrency within an 8 GiB node and a small RDS instance (pool size must exceed Sidekiq concurrency).
    FABRICATE_SIDEKIQ_CONCURRENCY = "10"
    FABRICATE_DB_POOL_SIZE        = "20"
    FABRICATE_REDIS_PASSWORD      = var.redis_password
    FABRICATE_REDIS_URL           = "rediss://:${var.redis_password}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"

    # Amazon Bedrock as the AI provider. The app only enables it when FABRICATE_BEDROCK_API_KEY is set (generated in
    # bedrock.tf). FABRICATE_AWS_REGION is the call region; FABRICATE_BEDROCK_REGION is the inference-profile prefix
    # (us.anthropic.claude-*, ...).
    FABRICATE_BEDROCK_REGION  = local.bedrock_prefix
    FABRICATE_BEDROCK_API_KEY = aws_iam_service_specific_credential.bedrock.service_credential_secret
  }
  sensitive = true
}

# Consumed by the root module to install the Fluent Bit log collector (null when logging is disabled).
output "log_collector" {
  value = var.enable_cloudwatch_logs ? {
    namespace       = local.collector_namespace
    service_account = local.collector_sa_name
    role_arn        = aws_iam_role.log_collector[0].arn
    log_group       = local.application_log_group
    region          = var.region
  } : null
}
