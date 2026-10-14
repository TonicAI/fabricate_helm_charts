# Amazon Bedrock for the app's AI features. Fabricate only treats Bedrock as available when FABRICATE_BEDROCK_API_KEY is
# set (the IAM role used for S3 is not enough), so a dedicated IAM user with a Bedrock API key (service-specific
# credential) is created and its key is passed to the app through the env Secret.

resource "aws_iam_user" "bedrock" {
  count = var.enable_bedrock ? 1 : 0

  name = "${var.cluster}-bedrock"
}

resource "aws_iam_user_policy" "bedrock" {
  count = var.enable_bedrock ? 1 : 0

  name = "bedrock-invoke"
  user = aws_iam_user.bedrock[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Required for requests authenticated with a Bedrock API key (bearer token).
        Effect   = "Allow"
        Action   = ["bedrock:CallWithBearerToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
        ]
      },
    ]
  })
}

resource "aws_iam_service_specific_credential" "bedrock" {
  count = var.enable_bedrock ? 1 : 0

  service_name        = "bedrock.amazonaws.com"
  user_name           = aws_iam_user.bedrock[0].name
  credential_age_days = var.bedrock_api_key_age_days

  depends_on = [aws_iam_user_policy.bedrock]
}

# Existing deployments: these resources gained count (enable_bedrock); keep them instead of replacing the key.
moved {
  from = aws_iam_user.bedrock
  to   = aws_iam_user.bedrock[0]
}

moved {
  from = aws_iam_user_policy.bedrock
  to   = aws_iam_user_policy.bedrock[0]
}

moved {
  from = aws_iam_service_specific_credential.bedrock
  to   = aws_iam_service_specific_credential.bedrock[0]
}
