# CloudWatch Logs: EKS control plane, RDS PostgreSQL, ElastiCache Redis and all pod logs (collected by Fluent Bit,
# installed by the root module with the IRSA role below). Every log group is created here with
# retention_in_days = var.cloudwatch_log_retention_days, so no group is auto-created without a retention policy.

locals {
  log_retention = var.cloudwatch_log_retention_days
  # Pod/container logs written by Fluent Bit.
  application_log_group = "/aws/eks/${var.cluster}/application"
  collector_namespace   = "amazon-cloudwatch"
  collector_sa_name     = "aws-for-fluent-bit"
}

resource "aws_cloudwatch_log_group" "cluster" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name              = "/aws/eks/${var.cluster}/cluster"
  retention_in_days = local.log_retention
}

resource "aws_cloudwatch_log_group" "application" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name              = local.application_log_group
  retention_in_days = local.log_retention
}

resource "aws_cloudwatch_log_group" "rds" {
  for_each = var.enable_cloudwatch_logs && var.enable_rds ? toset(["postgresql", "upgrade"]) : toset([])

  name              = "/aws/rds/instance/${var.cluster}/${each.value}"
  retention_in_days = local.log_retention
}

# ElastiCache Redis slow-log and engine-log, delivered by the replication group's log_delivery_configuration.
resource "aws_cloudwatch_log_group" "redis" {
  for_each = var.enable_cloudwatch_logs && var.enable_elasticache ? toset(["slow-log", "engine-log"]) : toset([])

  name              = "/aws/elasticache/${var.cluster}/${each.value}"
  retention_in_days = local.log_retention
}

# IRSA role for the Fluent Bit service account.
resource "aws_iam_role" "log_collector" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name = "${var.cluster}-log-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_id}:sub" = "system:serviceaccount:${local.collector_namespace}:${local.collector_sa_name}"
          "${local.oidc_provider_id}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "log_collector" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name = "cloudwatch-logs"
  role = aws_iam_role.log_collector[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
      Resource = "${aws_cloudwatch_log_group.application[0].arn}:*"
    }]
  })
}
