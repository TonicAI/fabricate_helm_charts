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

variable "kube_region" {
  description = "Cluster region (e.g. GKE Tau T2A defaults target **us-central1** zones **a/b** — other regions/zones often lack **t2a-***)."
  type        = string
  default     = "us-central1"
}

variable "kube_cluster" {
  description = "Cluster name (GKE or EKS)"
  type        = string
  default     = "fabricate-cluster"
}

variable "kube_helm_release" {
  description = "Helm release name (must be non-empty)."
  type        = string
  default     = "fabricate"

  validation {
    condition     = trimspace(var.kube_helm_release) != ""
    error_message = "kube_helm_release must be non-empty."
  }
}

variable "kube_helm_timeout" {
  description = "Seconds for Helm install/upgrade to complete (pods ready, hooks). Increase if Terraform fails with context deadline exceeded on slow clusters or LoadBalancer provisioning."
  type        = number
  default     = 1200
}

variable "kube_helm_namespace" {
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

variable "fabricate_registry_host" {
  description = "Container registry hostname for Helm values registry.host (e.g. quay.io). If empty, the chart default in values.yaml is used."
  type        = string
  default     = "quay.io"
}

variable "fabricate_registry_username" {
  description = "If non-empty, sets Helm registry.username (otherwise chart default in values.yaml applies)."
  type        = string
  default     = ""
}

variable "fabricate_registry_password" {
  description = "Registry password for kubernetes.io/dockerconfigjson secret (Helm registry.password). Prefer TF_VAR_fabricate_registry_password or a gitignored -var-file, not terraform.tfvars."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Additional tags (AWS) / labels (GCP) applied to all resources created by the cloud module, merged over the built-in Project/ManagedBy defaults. On GCP, keys and values must be lowercase letters, digits, underscores or dashes."
  type        = map(string)
  default     = {}
}

variable "kube_vpc_id" {
  description = "AWS only: VPC to use. Empty uses the account's default VPC."
  type        = string
  default     = ""
}

variable "kube_subnet_ids" {
  description = "AWS only: subnet IDs (at least two AZs) for the cluster, RDS and ElastiCache. Empty picks two automatically from the VPC."
  type        = list(string)
  default     = []
}

variable "skip_helm" {
  description = "When true, only provision cloud resources (cluster, databases, storage, IAM, ...) and skip all Helm releases (Fabricate chart and, on AWS, the Fluent Bit log collector). Install the chart yourself with helm; see the README."
  type        = bool
  default     = false
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
