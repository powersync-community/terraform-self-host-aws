variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "domain" {
  type = string
}

variable "route53_zone_id" {
  type = string
}

variable "idle_timeout" {
  type = number
}

variable "deregistration_delay" {
  type = number
}

variable "jwks_json" {
  type        = string
  description = "Public JWKS JSON served as a fixed-response at /api/auth/keys. Must be <= 1024 bytes (ALB limit)."
}
