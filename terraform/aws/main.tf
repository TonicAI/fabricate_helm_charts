# EKS with Auto Mode enabled.
# Compute, Load Balancing, and Storage are managed by AWS.
provider "aws" {
  default_tags {
    tags = merge(
      {
        Project   = "fabricate"
        ManagedBy = "terraform"
      },
      var.tags,
    )
  }
}

# Network: the account's default VPC unless var.vpc_id is set; subnets are var.vpc_subnet_ids or picked automatically.
data "aws_vpcs" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

locals {
  vpc_id = var.vpc_id != "" ? var.vpc_id : tolist(data.aws_vpcs.default.ids)[0]
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

data "aws_subnet" "selected" {
  for_each = length(var.vpc_subnet_ids) == 0 ? toset(data.aws_subnets.selected.ids) : toset([])
  id       = each.value
}

locals {
  # EKS cannot create control plane instances in these AZs. Zone IDs (not names) are used because AZ names map
  # to different physical zones per account: us-east-1 use1-az3, us-west-1 usw1-az2, ca-central-1 cac1-az3.
  eks_unsupported_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  # Automatic choice: one subnet per AZ (skipping unsupported zones), the first two by AZ name.
  subnet_by_az = {
    for s in data.aws_subnet.selected : s.availability_zone => s.id
    if !contains(local.eks_unsupported_zone_ids, s.availability_zone_id)
  }
  auto_subnet_ids = [for az in slice(sort(keys(local.subnet_by_az)), 0, min(2, length(local.subnet_by_az))) : local.subnet_by_az[az]]
  subnet_ids      = length(var.vpc_subnet_ids) > 0 ? var.vpc_subnet_ids : local.auto_subnet_ids
}

# Subnet tags are still required for discovery by the Auto Mode Load Balancer.
resource "aws_ec2_tag" "subnet_role_elb" {
  for_each = toset(local.subnet_ids)

  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "subnet_cluster_shared" {
  for_each = toset(local.subnet_ids)

  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster}"
  value       = "shared"
}

locals {
  # Bedrock inference-profile prefix: explicit, else the geography of the region.
  bedrock_prefix = var.bedrock_inference_prefix != "" ? var.bedrock_inference_prefix : (
    startswith(var.region, "us-") ? "us" : startswith(var.region, "eu-") ? "eu" : startswith(var.region, "ap-") ? "apac" : "global"
  )

  node_selector = {
    "kubernetes.io/arch"               = "arm64"
    "node.kubernetes.io/instance-type" = var.eks_instance_type
  }
}

# Cluster role. EKS Auto Mode needs sts:TagSession in the trust policy and the Auto Mode managed policies on THIS
# role (not the node role): they let EKS create the node instance profile, launch EC2, provision EBS and load balancers.
resource "aws_iam_role" "cluster" {
  name = var.cluster

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.cluster.name
}

# Node role used by Auto Mode nodes: only the minimal worker policy and ECR pull.
resource "aws_iam_role" "node" {
  name = "${var.cluster}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  policy_arn = each.value
  role       = aws_iam_role.node.name
}

# Customer managed key for Kubernetes Secrets envelope encryption (eks_secrets_encryption).
resource "aws_kms_key" "eks_secrets" {
  count = var.eks_secrets_encryption ? 1 : 0

  description             = "${var.cluster} EKS Secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "eks_secrets" {
  count = var.eks_secrets_encryption ? 1 : 0

  name          = "alias/${var.cluster}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets[0].key_id
}

# The cluster role encrypts / decrypts the Secrets with the key.
resource "aws_iam_role_policy" "cluster_secrets_kms" {
  count = var.eks_secrets_encryption ? 1 : 0

  name = "secrets-kms"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = aws_kms_key.eks_secrets[0].arn
    }]
  })
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster
  role_arn = aws_iam_role.cluster.arn
  version  = var.eks_version # Auto Mode requires 1.30+

  # Required by EKS Auto Mode: it provides kube-proxy, CoreDNS, VPC CNI and the EBS CSI driver itself.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = local.subnet_ids
    # Nodes and pods reach the API server through the private endpoint (which also keeps working when the public one
    # is restricted); the public endpoint is for kubectl and Terraform.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.eks_public_access_cidrs
  }

  dynamic "encryption_config" {
    for_each = var.eks_secrets_encryption ? [1] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = aws_kms_key.eks_secrets[0].arn
      }
    }
  }

  enabled_cluster_log_types = var.enable_cloudwatch_logs ? ["api", "audit", "authenticator", "controllerManager", "scheduler"] : []

  # EKS Auto Mode Configuration
  compute_config {
    enabled       = true
    node_pools    = ["system"] # Fabricate gets its own NodePool from the Helm chart (additionalResources)
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy.cluster_secrets_kms,
    aws_iam_role_policy_attachment.cluster_policies,
    aws_iam_role_policy_attachment.node_policies,
    aws_ec2_tag.subnet_role_elb,
    aws_ec2_tag.subnet_cluster_shared,
  ]
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["0000000000000000000000000000000000000000"]
}

locals {
  oidc_issuer      = aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider_id = trimprefix(local.oidc_issuer, "https://")
  # Chart service account (<app>-<environment>-sa). Used in the role trust policy below and passed to the chart
  # (helm_service_account output), so the two always match.
  service_account_name = "${var.name_prefix}-sa"
}

# IAM role for the Fabricate service account (IRSA).
resource "aws_iam_role" "fabricate" {
  name = "${var.cluster}-fabricate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_id}:sub" = "system:serviceaccount:${var.helm_namespace}:${local.service_account_name}"
          "${local.oidc_provider_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Bedrock access for the app's role (SDK calls via IRSA; the AI provider itself uses the API key in bedrock.tf). Cross-region inference profiles (e.g. us.anthropic.*,
# global.anthropic.*) need the inference-profile ARN in this account as well as the foundation models they route to.
moved {
  from = aws_iam_role_policy.fabricate_bedrock
  to   = aws_iam_role_policy.fabricate_bedrock[0]
}

resource "aws_iam_role_policy" "fabricate_bedrock" {
  count = var.enable_bedrock ? 1 : 0

  name = "bedrock"
  role = aws_iam_role.fabricate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
      ]
    }]
  })
}
