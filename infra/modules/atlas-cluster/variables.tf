variable "project_id" {
  description = "Atlas project ID the cluster is created in. The Service Account must hold Project Owner on it."
  type        = string
}

variable "name_prefix" {
  description = "Name prefix shared with the AWS side (e.g. powersync) -> cluster powersync-cluster."
  type        = string
}

variable "instance_size" {
  description = "Atlas instance size. M10 is the floor for AWS PrivateLink (M0/shared cannot do private endpoints)."
  type        = string
  default     = "M10"
}

variable "region_name" {
  description = "Atlas region name (Atlas spelling, e.g. US_EAST_1). Match the AWS VPC region for single-region PrivateLink."
  type        = string
  default     = "US_EAST_1"
}

variable "mongo_db_major_version" {
  description = "Major MongoDB version (e.g. 8.0). null lets Atlas pick the current default."
  type        = string
  default     = null
}

variable "db_username" {
  description = "SCRAM database user PowerSync authenticates as. The password is generated here and never committed."
  type        = string
  default     = "powersync"
}

variable "storage_database" {
  description = "Name of the PowerSync bucket-storage database (the /buckets path in storage_uri). Used to scope the full + API storage roles."
  type        = string
  default     = "buckets"
}

variable "source_database" {
  description = "Name of the source database (the /db path in data_source_uri). Scopes the source user's readWrite role."
  type        = string
  default     = "db"
}

variable "api_role_name" {
  description = "Name of the custom least-privilege API storage role. Custom roles are project-scoped, so a second instance of this module in the same project must pass a distinct name to avoid a collision."
  type        = string
  default     = "powersyncApiStorage"
}

variable "create_private_endpoint" {
  description = "Whether this instance creates the Atlas PrivateLink endpoint service + AWS interface endpoint. Atlas permits only one private endpoint service per region per project, and a single regional endpoint already serves every cluster in that region. So the first instance creates it (true); a second cluster in the same region must reuse it (false) and pass existing_vpc_endpoint_id."
  type        = bool
  default     = true
}

variable "existing_vpc_endpoint_id" {
  description = "When create_private_endpoint = false, the AWS interface endpoint id of the shared regional Atlas endpoint (this project's other cluster created it). The cluster's -pri connection string is matched against this id."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC the Atlas interface endpoint is created in (from the network module)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs the interface endpoint places ENIs in (from the network module)."
  type        = list(string)
}

variable "endpoint_sg_id" {
  description = "Security group for the Atlas interface endpoint (from the network module, accepts the Mongo port range from the ECS tasks)."
  type        = string
}
