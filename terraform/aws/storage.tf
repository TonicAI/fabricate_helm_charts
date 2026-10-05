# S3 bucket for Active Storage (generated files). Access is through the Fabricate IRSA role (no access keys).

data "aws_caller_identity" "current" {}

locals {
  s3_bucket_name = "${var.kube_cluster}-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket" "storage" {
  bucket        = local.s3_bucket_name
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role_policy" "fabricate_s3" {
  name = "s3"
  role = aws_iam_role.fabricate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.storage.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.storage.arn}/*"
      },
    ]
  })
}
