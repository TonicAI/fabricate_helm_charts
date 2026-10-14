# Amazon SES for outgoing email (invites, notifications). Creates a verified sender address and an IAM user whose SMTP
# credentials are passed to the app as FABRICATE_MAIL_ADDRESS / _PORT / _USER_NAME / _PASSWORD (outputs.tf helm_env).
# The sender is var.ses_email (also used as FABRICATE_MAIL_FROM). Anything set in fabricate_env overrides these values.
#
# After the first apply AWS emails a verification link to the sender address; click it once. New SES accounts are in
# the sandbox: mail can only be sent to verified addresses until you request production access in the SES console.

locals {
  ses_enabled = var.enable_ses && trimspace(var.ses_email) != ""
}

resource "aws_sesv2_email_identity" "sender" {
  count = local.ses_enabled ? 1 : 0

  email_identity = trimspace(var.ses_email)
}

resource "aws_iam_user" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0

  name = "${var.cluster}-ses-smtp"
}

resource "aws_iam_user_policy" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0

  name = "ses-send"
  user = aws_iam_user.ses_smtp[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  count = local.ses_enabled ? 1 : 0

  user = aws_iam_user.ses_smtp[0].name
}
