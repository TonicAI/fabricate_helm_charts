# HTTPS listener for the ALB (EKS Auto Mode). The certificate is var.https_cert_arn when set; otherwise a
# self-signed certificate is generated here on the first apply and imported into ACM (valid until 2050; browsers show a warning).
# The ARN goes into the IngressClassParams (outputs.tf); the listen-ports / ssl-redirect Ingress annotations open
# HTTP:80 -> HTTPS:443 and FABRICATE_PROTOCOL is set to https.

locals {
  # The HTTPS listener belongs to the ALB, so it only exists while the ALB is the ingress (enable_alb).
  https_on          = var.enable_alb && var.enable_https
  needs_self_signed = local.https_on && var.https_cert_arn == ""

  certificate_arn = !local.https_on ? "" : (
    var.https_cert_arn != "" ? var.https_cert_arn : aws_acm_certificate.self_signed[0].arn
  )
}

resource "tls_private_key" "self_signed" {
  count = local.needs_self_signed ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "self_signed" {
  count = local.needs_self_signed ? 1 : 0

  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "fabricate.localhost"
    organization = "Fabricate"
  }

  dns_names             = ["fabricate.localhost"]
  validity_period_hours = 212256 # ~24 years: valid until the end of 2050 when created in 2026
  allowed_uses          = ["digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "self_signed" {
  count = local.needs_self_signed ? 1 : 0

  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}
