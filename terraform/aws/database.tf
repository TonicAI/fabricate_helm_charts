# Managed PostgreSQL (RDS, enable_rds) and Redis (ElastiCache, enable_elasticache) in the cluster subnets (default VPC
# unless vpc_id is set). Reachable only from the EKS cluster security group (pods on Auto Mode nodes use it). When a
# flag is false the resource is not created and the chart runs that service inside the cluster instead (outputs.tf).

locals {
  db_name     = "fabricate"
  db_username = "fabricate"
  data_sg_id  = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_security_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name        = "${var.cluster}-rds"
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
  count = var.enable_elasticache ? 1 : 0

  name        = "${var.cluster}-redis"
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
# AZs inside the VPC. An explicit var.vpc_subnet_ids restricts it to those subnets.
resource "aws_db_subnet_group" "this" {
  count = var.enable_rds ? 1 : 0

  name       = var.cluster
  subnet_ids = length(var.vpc_subnet_ids) > 0 ? var.vpc_subnet_ids : data.aws_subnets.selected.ids
}

resource "aws_db_instance" "this" {
  count = var.enable_rds ? 1 : 0

  identifier = var.cluster

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

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  backup_retention_period   = var.rds_backup_retention_days
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.cluster}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  enabled_cloudwatch_logs_exports = var.enable_cloudwatch_logs ? ["postgresql", "upgrade"] : []

  depends_on = [aws_cloudwatch_log_group.rds]

  lifecycle {
    # The snapshot name must be unique per destroy (a fixed name fails with DBSnapshotAlreadyExists once an earlier
    # destroy left its snapshot behind). timestamp() is evaluated at create time and then kept, so there is no
    # perpetual diff; the name stored in state is what destroy uses.
    ignore_changes = [final_snapshot_identifier]
  }
}

resource "aws_elasticache_subnet_group" "this" {
  count = var.enable_elasticache ? 1 : 0

  name       = var.cluster
  subnet_ids = local.subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  count = var.enable_elasticache ? 1 : 0

  replication_group_id = var.cluster
  description          = "Fabricate Redis (${var.cluster})"

  engine         = "redis"
  engine_version = var.elasticache_engine_version
  node_type      = var.elasticache_node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_password

  # Required by ElastiCache to change log_delivery_configuration on an existing replication group
  # (otherwise ModifyReplicationGroup fails with "set the apply-immediately parameter to true").
  apply_immediately = true

  dynamic "log_delivery_configuration" {
    for_each = aws_cloudwatch_log_group.redis

    content {
      destination      = log_delivery_configuration.value.name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = log_delivery_configuration.key
    }
  }
}

# Existing deployments: these resources gained count (enable_rds / enable_elasticache); keep them, do not replace.
moved {
  from = aws_security_group.rds
  to   = aws_security_group.rds[0]
}

moved {
  from = aws_db_subnet_group.this
  to   = aws_db_subnet_group.this[0]
}

moved {
  from = aws_db_instance.this
  to   = aws_db_instance.this[0]
}

moved {
  from = aws_security_group.redis
  to   = aws_security_group.redis[0]
}

moved {
  from = aws_elasticache_subnet_group.this
  to   = aws_elasticache_subnet_group.this[0]
}

moved {
  from = aws_elasticache_replication_group.this
  to   = aws_elasticache_replication_group.this[0]
}
