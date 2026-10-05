provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(
    {
      project    = "fabricate"
      managed_by = "terraform"
    },
    var.tags,
  )
}

data "google_client_config" "default" {}

data "google_project" "current" {
  project_id = var.project_id
}

# Tau T2A default `gke_machine_type` = t2a-standard-2 (8 GiB); node zones [region]-a / [region]-b when unset.
locals {
  gke_node_locations = length(var.gke_node_locations) > 0 ? var.gke_node_locations : ["${var.region}-a", "${var.region}-b"]
}

resource "google_project_service" "container" {
  project = var.project_id
  service = "container.googleapis.com"

  disable_on_destroy = false
}

# -----------------------------
# GKE STANDARD CLUSTER
# -----------------------------
# Fabricate deno_sandbox requires Landlock ABI V3 (CONFIG_SECURITY_LANDLOCK + kernel 6.2+).
# GKE Autopilot always uses COS, which is built without Landlock — not usable for Fabricate.
# Ubuntu GKE nodes (linux-gke) include Landlock; verify after deploy (see README).
resource "google_container_cluster" "primary" {
  project  = var.project_id
  name     = var.kube_cluster
  location = var.region

  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  network    = "default"
  subnetwork = "default"

  node_locations = local.gke_node_locations

  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${data.google_project.current.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  depends_on = [
    google_project_service.container,
  ]

  lifecycle {
    precondition {
      condition     = var.gke_node_image_type == "UBUNTU_CONTAINERD"
      error_message = "Fabricate requires UBUNTU_CONTAINERD nodes (Landlock). COS_CONTAINERD disables CONFIG_SECURITY_LANDLOCK."
    }
  }
}

resource "google_container_node_pool" "primary" {
  project  = var.project_id
  name     = "${var.kube_cluster}-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name

  initial_node_count = var.gke_min_nodes

  autoscaling {
    min_node_count = var.gke_min_nodes
    max_node_count = var.gke_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.gke_machine_type
    disk_size_gb = var.gke_disk_size_gb
    image_type   = var.gke_node_image_type

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      fabricate = "node"
    }
  }

  depends_on = [
    google_container_cluster.primary,
  ]
}

# IngressClass "gce" is created by GKE when the HTTP load balancing addon is enabled (addons_config above).
# Do not manage it with the Kubernetes provider here — during cluster updates Terraform refresh can run
# before the API endpoint is reachable and fail with localhost:80 connection refused.
