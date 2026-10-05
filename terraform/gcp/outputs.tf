output "host" {
  value = "https://${google_container_cluster.primary.endpoint}"
}

output "ca_certificate" {
  value = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

output "token" {
  value     = data.google_client_config.default.access_token
  sensitive = true
}

output "helm_service_account" {
  value = { create = true }
}

# GKE PD CSI driver implements VOLUME_MOUNT_GROUP; fsGroup alone is sufficient.
# GKE Autopilot blocks runAsUser: 0, so initChown must stay disabled.
output "helm_volumes_security" {
  value = {
    volumesSecurity = {
      initChown = { enabled = false }
    }
  }
}

# Multi-zone Fabricate workloads share multiple RWO PD claims (data/storage/sockets).
# Immediate default StorageClasses pin each PVC to arbitrary zones → scheduling conflict.
output "helm_extra_values" {
  value = {
    # No managed DB on GCP: use the chart's in-cluster PostgreSQL / Redis.
    services = {
      postgresql = { enabled = true }
      redis      = { enabled = true }
    }
    # GKE Arm node pools taint kubernetes.io/arch=arm64:NoSchedule — required for scheduling.
    tolerations = [
      {
        key      = "kubernetes.io/arch"
        operator = "Equal"
        value    = "arm64"
        effect   = "NoSchedule"
      },
    ]
    volumesProvisioning = {
      delayedBindingStorageClass = {
        enabled              = true
        provisioner          = "pd.csi.storage.gke.io"
        reclaimPolicy        = "Delete"
        allowVolumeExpansion = true
        parameters = {
          type = "pd-balanced"
        }
      }
    }
  }
}

output "helm_env" {
  value     = {}
  sensitive = true
}

# No log collector on GCP (GKE ships logs to Cloud Logging by default).
output "log_collector" {
  value = null
}
