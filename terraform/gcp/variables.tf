variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "cluster" {
  type = string
}

variable "helm_namespace" {
  type = string
}

variable "helm_release" {
  type = string
}

variable "gke_min_nodes" {
  description = "Minimum nodes per zone in the default pool (regional cluster: 1 here + two zones → 2 nodes total)."
  type        = number
  default     = 1
}

variable "gke_max_nodes" {
  description = "Maximum nodes per zone when autoscaling (set equal to gke_min_nodes to pin one node per zone)."
  type        = number
  default     = 1
}

variable "gke_node_locations" {
  description = "Exact zones for worker nodes. Leave empty for [region]-a + [region]-b (Tau T2A + us-central1: **-c** often has no **t2a-*** SKU)."
  type        = list(string)
  default     = []
}

variable "gke_machine_type" {
  description = <<-EOT
    GKE Standard node VM shape.

    Default **Tau T2A Arm** **`t2a-standard-2`** (2 vCPU, **8 GiB**). Use **`t2a-standard-4`** (16 GiB) when zones have capacity. Many regions/zones omit **t2a-*** — verify:

      gcloud compute machine-types list --zones=REGION-ZONE --filter=name:t2a

    Arm workloads need **linux/arm64**. For x86 use **e3-standard-* / e2-standard-*`.
  EOT
  type        = string
  default     = "t2a-standard-2"
}

variable "gke_disk_size_gb" {
  type    = number
  default = 50
}

variable "gke_node_image_type" {
  description = "Node image for Standard clusters. Use UBUNTU_CONTAINERD for Fabricate (Landlock). COS_CONTAINERD omits CONFIG_SECURITY_LANDLOCK."
  type        = string
  default     = "UBUNTU_CONTAINERD"

  validation {
    condition     = contains(["UBUNTU_CONTAINERD", "COS_CONTAINERD"], var.gke_node_image_type)
    error_message = "gke_node_image_type must be UBUNTU_CONTAINERD or COS_CONTAINERD."
  }
}

variable "tags" {
  description = "Additional tags (AWS) / labels (GCP) applied to all resources created by the cloud module, merged over the built-in Project/ManagedBy defaults. On GCP, keys and values must be lowercase letters, digits, underscores or dashes."
  type        = map(string)
  default     = {}
}

variable "database_password" {
  description = "Unused on GKE (in-cluster PostgreSQL gets its password through Helm env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_password" {
  description = "Unused on GKE (in-cluster Redis gets its password through Helm env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vpc_id" {
  description = "Unused on GKE."
  type        = string
  default     = ""
}

variable "vpc_subnet_ids" {
  description = "Unused on GKE."
  type        = list(string)
  default     = []
}

variable "name_prefix" {
  description = "Chart naming prefix <app>-<environment> (e.g. fabricate-prod). Unused on GKE."
  type        = string
  default     = "fabricate-prod"
}

variable "https_cert_arn" {
  description = "Unused on GKE."
  type        = string
  default     = ""
}

variable "ses_email" {
  description = "Unused on GKE."
  type        = string
  default     = ""
}

variable "enable_ses" {
  description = "Unused on GKE."
  type        = bool
  default     = true
}

variable "enable_https" {
  description = "Unused on GKE."
  type        = bool
  default     = true
}

variable "enable_bedrock" {
  description = "Unused on GKE."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Unused on GKE (PostgreSQL runs in the cluster)."
  type        = bool
  default     = true
}

variable "enable_elasticache" {
  description = "Unused on GKE (Redis runs in the cluster)."
  type        = bool
  default     = true
}

variable "enable_alb" {
  description = "Unused on GKE."
  type        = bool
  default     = true
}
