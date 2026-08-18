terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Master password — generated, never committed. special=false avoids URL-encoding headaches when
# the value is spliced into connection strings.
resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.name_prefix}-db" }
}

# Enable Postgres logical replication (what PowerSync's replicator consumes). This is a static
# parameter, so it applies on (re)boot — a freshly created instance comes up with it already set.
resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-pg${var.engine_version}"
  family = "postgres${var.engine_version}"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The database is reachable on 5432 only from the ECS tasks and any admin CIDRs (e.g. your laptop
# for seeding). It is publicly accessible (demo convenience) but this SG is the actual gate.
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "PowerSync RDS Postgres"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  dynamic "ingress" {
    for_each = length(var.admin_cidr) > 0 ? [1] : []
    content {
      description = "Postgres from admin CIDRs (seeding / local client)"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = var.admin_cidr
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-db-sg" }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.source_db_name
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  parameter_group_name    = aws_db_parameter_group.this.name
  publicly_accessible     = true # demo: lets the example client seed from a laptop. Set false + private subnets for production.
  backup_retention_period = 1

  # Demo: keep teardown frictionless. For production, enable deletion protection and a final snapshot.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  tags = { Name = "${var.name_prefix}-pg" }
}
