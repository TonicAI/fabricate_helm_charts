# Managed PostgreSQL (RDS) and Redis (ElastiCache) in the cluster subnets (default VPC unless kube_vpc_id is set).
# Reachable only from the EKS cluster security group (pods on Auto Mode nodes use it).

locals {
  db_name     = "fabricate"
  db_username = "fabricate"
  data_sg_id  = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group" "rds" {
  name        = "${var.kube_cluster}-rds"
  description = "PostgreSQL access from the EKS cluster"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.data_sg_id]
  }
}

resource "aws_security_group" "redis" {
  name        = "${var.kube_cluster}-redis"
  description = "Redis access from the EKS cluster"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [local.data_sg_id]
  }
}

# RDS gets every subnet of the VPC (all AZs) rather than only the two cluster subnets: not every AZ has capacity for
# every instance class / storage type (InvalidVPCNetworkStateFault), and RDS picks one that does. Pods reach it across
# AZs inside the VPC. An explicit var.kube_subnet_ids restricts it to those subnets.
resource "aws_db_subnet_group" "this" {
  name       = var.kube_cluster
  subnet_ids = length(var.kube_subnet_ids) > 0 ? var.kube_subnet_ids : data.aws_subnets.selected.ids
}

resource "aws_db_instance" "this" {
  identifier = var.kube_cluster

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = local.db_name
  username = local.db_username
  password = var.database_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  backup_retention_period   = var.rds_backup_retention_days
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.kube_cluster}-final"

  enabled_cloudwatch_logs_exports = var.enable_cloudwatch_logs ? ["postgresql", "upgrade"] : []

  depends_on = [aws_cloudwatch_log_group.rds]
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.kube_cluster
  subnet_ids = local.subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.kube_cluster
  description          = "Fabricate Redis (${var.kube_cluster})"

  engine         = "redis"
  engine_version = var.elasticache_engine_version
  node_type      = var.elasticache_node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_password
}
