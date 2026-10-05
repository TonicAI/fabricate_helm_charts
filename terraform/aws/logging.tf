# CloudWatch Logs: EKS control plane, RDS PostgreSQL and all pod logs (collected by Fluent Bit, installed by the
# root module with the IRSA role below). Log groups are created here so retention is managed.

locals {
  log_retention = var.cloudwatch_log_retention_days
  # Pod/container logs written by Fluent Bit.
  application_log_group = "/aws/eks/${var.kube_cluster}/application"
  collector_namespace   = "amazon-cloudwatch"
  collector_sa_name     = "aws-for-fluent-bit"
}

resource "aws_cloudwatch_log_group" "cluster" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name              = "/aws/eks/${var.kube_cluster}/cluster"
  retention_in_days = local.log_retention
}

resource "aws_cloudwatch_log_group" "application" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name              = local.application_log_group
  retention_in_days = local.log_retention
}

resource "aws_cloudwatch_log_group" "rds" {
  for_each = var.enable_cloudwatch_logs ? toset(["postgresql", "upgrade"]) : toset([])

  name              = "/aws/rds/instance/${var.kube_cluster}/${each.value}"
  retention_in_days = local.log_retention
}

# IRSA role for the Fluent Bit service account.
resource "aws_iam_role" "log_collector" {
  count = var.enable_cloudwatch_logs ? 1 : 0

  name = "${var.kube_cluster}-log-collector"

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
