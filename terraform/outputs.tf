output "fabricate_secret_key_base" {
  description = "Fabricate SECRET_KEY_BASE passed to Helm (env.SECRET_KEY_BASE); also in cluster Secret."
  value       = random_password.fabricate_secret_key_base.result
  sensitive   = true
}

output "fabricate_database_password" {
  description = "Database password (RDS on AWS, in-cluster Postgres on GCP) unless overridden in fabricate_env."
  value       = random_password.fabricate_database_password.result
  sensitive   = true
}

output "fabricate_redis_password" {
  description = "Redis password (ElastiCache AUTH token on AWS, in-cluster Redis on GCP) unless overridden in fabricate_env."
  value       = random_password.fabricate_redis_password.result
  sensitive   = true
}

output "fabricate_ingress" {
  description = "Helm values.ingress passed to the chart (cloud defaults merged with var.fabricate_ingress): provider/class follow var.cloud unless overridden."
  value       = local.fabricate_ingress
}

output "fabricate_host" {
  description = "fabricate_env.FABRICATE_HOST when set in Terraform; otherwise null. If omitted, the Helm chart sets FABRICATE_HOST at upgrade time to <load balancer IP>.nip.io from the Ingress (see chart fabricate.resolvedLbNipHost)."
  value       = trimspace(lookup(var.fabricate_env, "FABRICATE_HOST", "")) != "" ? trimspace(var.fabricate_env["FABRICATE_HOST"]) : null
  sensitive   = true
}

output "fabricate_ingress_address" {
  description = "Load balancer address of the Fabricate Ingress: DNS name on AWS (ALB; point a CNAME at it), IP on GCP. Null if skip_helm is true or it was not ready when the apply finished."
  value = try(
    coalesce(
      data.kubernetes_ingress_v1.fabricate[0].status[0].load_balancer[0].ingress[0].hostname,
      data.kubernetes_ingress_v1.fabricate[0].status[0].load_balancer[0].ingress[0].ip,
    ),
    null,
  )
}

output "helm_values" {
  description = "Complete values.yaml for the Fabricate chart (generated secrets and cloud wiring included, registry password excluded). Use with skip_helm = true: terraform output -raw helm_values > values.generated.yaml, then helm upgrade --install fabricate . -f values.generated.yaml --set-string registry.password=... Contains secrets: do not commit."
  value = yamlencode(merge(
    local.helm_values,
    {
      registry = {
        host     = var.fabricate_registry_host
        username = var.fabricate_registry_username
      }
    },
  ))
  sensitive = true
}
