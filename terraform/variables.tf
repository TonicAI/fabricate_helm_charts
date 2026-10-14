variable "cloud" {
  description = "gcp (GKE) or aws (EKS). Same variables otherwise; run terraform init -reconfigure after changing. Drives Helm ingress defaults: gcp → provider/class gce (GKE L7), aws → alb (EKS + AWS LB Controller); override with fabricate_ingress."
  type        = string
  const       = true

  validation {
    condition     = contains(["gcp", "aws"], var.cloud)
    error_message = "cloud must be gcp or aws."
  }
}

variable "project_id" {
  description = "GCP project ID when cloud is gcp; leave empty on aws (ignored)."
  type        = string
  default     = ""
}

variable "region" {
  description = "Cluster region (e.g. GKE Tau T2A defaults target **us-central1** zones **a/b** — other regions/zones often lack **t2a-***)."
  type        = string
  default     = "us-central1"
}

variable "cluster" {
  description = "Cluster name (GKE or EKS)"
  type        = string
  default     = "fabricate-cluster"
}

variable "skip_helm" {
  description = "When true, only provision cloud resources (cluster, databases, storage, IAM, ...) and skip all Helm releases (Fabricate chart and, on AWS, the Fluent Bit log collector). Install the chart yourself with helm; see the README."
  type        = bool
  default     = false
}

variable "helm_release" {
  description = "Helm release name (must be non-empty)."
  type        = string
  default     = "fabricate"

  validation {
    condition     = trimspace(var.helm_release) != ""
    error_message = "helm_release must be non-empty."
  }
}

variable "helm_timeout" {
  description = "Seconds for Helm install/upgrade to complete (pods ready, hooks). Increase if Terraform fails with context deadline exceeded on slow clusters or LoadBalancer provisioning."
  type        = number
  default     = 900
}

variable "helm_namespace" {
  description = "Namespace for the Fabricate Helm release"
  type        = string
  default     = "fabricate"
}

variable "fabricate_env" {
  description = "Extra env for Helm values.env (merged after auto-generated SECRET_KEY_BASE, FABRICATE_DATABASE_PASSWORD, FABRICATE_REDIS_PASSWORD from random_password — set a key here to override). Marked sensitive so plan/log output does not print these values."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "fabricate_ingress" {
  description = "Overrides for Helm ingress.* merged after cloud defaults (gcp→provider gce / class gce, aws→alb/alb). Use to force ingress-nginx on EKS: { provider = \"nginx\", class = \"nginx\" }."
  type        = map(any)
  default     = {}
}

variable "enable_ses" {
  description = "AWS only: set up Amazon SES for outgoing email (verified ses_email sender plus an IAM SMTP user wired into FABRICATE_MAIL_*). Set false to use your own SMTP server via FABRICATE_MAIL_* in fabricate_env."
  type        = bool
  default     = true
}

variable "enable_bedrock" {
  description = "AWS only: set up Amazon Bedrock as the AI provider (IAM user + API key wired into FABRICATE_BEDROCK_*, Bedrock access for the app role). Set false to use another provider through fabricate_env (e.g. FABRICATE_ANTHROPIC_API_KEY)."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "AWS only: use Amazon RDS for PostgreSQL. When false the chart runs PostgreSQL inside the EKS cluster instead."
  type        = bool
  default     = true
}

variable "enable_elasticache" {
  description = "AWS only: use Amazon ElastiCache for Redis. When false the chart runs Redis inside the EKS cluster instead."
  type        = bool
  default     = true
}

variable "ses_email" {
  description = "AWS only: sender address verified in Amazon SES (AWS emails it a confirmation link) and used as FABRICATE_MAIL_FROM. SES is only set up while this is set and enable_ses is true."
  type        = string
  default     = ""
}

variable "enable_alb" {
  description = "Use the EKS Auto Mode ALB as the ingress controller (AWS only): Terraform sets up the IngressClass, the HTTPS listener and the certificate. Set false to use a different ingress controller (for example nginx) that you install yourself; the Ingress is then configured under ingress.* in values.yaml."
  type        = bool
  default     = true
}

variable "enable_https" {
  description = "AWS only: open an HTTPS listener (443) on the ALB with HTTP -> HTTPS redirect and set FABRICATE_PROTOCOL=https. The certificate is https_cert_arn when set, otherwise a self-signed one generated on the first apply."
  type        = bool
  default     = true
}

variable "https_cert_arn" {
  description = "AWS only: ARN of an ACM certificate for the ALB HTTPS listener. Empty generates a self-signed certificate on the first apply."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags (AWS) / labels (GCP) applied to all resources created by the cloud module, merged over the built-in Project/ManagedBy defaults. On GCP, keys and values must be lowercase letters, digits, underscores or dashes."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "AWS only: VPC to use. Empty uses the account's default VPC."
  type        = string
  default     = ""
}

variable "vpc_subnet_ids" {
  description = "AWS only: subnet IDs (at least two AZs) for the cluster, RDS and ElastiCache. Empty picks two automatically from the VPC."
  type        = list(string)
  default     = []
}

variable "wait_for_ingress_timeout" {
  description = "Seconds to wait after the Helm release for the Ingress load balancer (ALB / GCE) to get an address, so it is available in the outputs. The apply continues if it is not ready in time."
  type        = number
  default     = 900
}

variable "fabricate_app" {
  description = "Chart `app` value. With fabricate_environment it forms the resource name prefix <app>-<environment> (e.g. fabricate-prod): workloads, PVCs, service account, ingress and, on AWS, the NodePool."
  type        = string
  default     = "fabricate"
}

variable "fabricate_environment" {
  description = "Chart `environment` value (second part of the name prefix, e.g. prod). Changing it renames workloads and PVCs."
  type        = string
  default     = "prod"
}
