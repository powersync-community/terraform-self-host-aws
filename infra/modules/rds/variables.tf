variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets for the DB subnet group. Public subnets, because this demo makes the instance publicly accessible (locked down by security group) so the example client can seed it from a laptop. For production, use private subnets and set publicly_accessible = false."
  type        = list(string)
}

variable "ecs_sg_id" {
  description = "Security group of the ECS tasks; allowed to reach the database on 5432."
  type        = string
}

variable "admin_cidr" {
  description = "Extra CIDRs allowed on 5432 (e.g. your workstation IP for seeding). May be empty."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  type = string
}

variable "allocated_storage" {
  type = number
}

variable "engine_version" {
  description = "Postgres major version (e.g. \"16\")."
  type        = string
}

variable "source_db_name" {
  description = "Initial database created on the instance (the source application database)."
  type        = string
}

variable "master_username" {
  type    = string
  default = "psadmin"
}
