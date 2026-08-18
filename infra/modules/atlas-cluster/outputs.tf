output "cluster_name" {
  value = mongodbatlas_advanced_cluster.this.name
}

output "standard_srv" {
  description = "Standard mongodb+srv:// host (public DNS). Resolves over the internet; usable only with an IP access-list entry. Phase 2 switches to the private-endpoint string instead."
  value       = mongodbatlas_advanced_cluster.this.connection_strings.standard_srv
  sensitive   = true
}

output "private_endpoint_srv" {
  description = "Private-endpoint-aware (-pri) mongodb+srv:// string for OUR interface endpoint. The cluster can list several private_endpoint entries (one per registered/stale AWS endpoint), each with a distinct pl-N host — picking the wrong one resolves to an endpoint not in this VPC (ENOTFOUND). Match on aws_vpc_endpoint.atlas.id so we always get the host that resolves to our ENIs."
  # Read from the data source (refreshed after the endpoint is live), not the resource, so this
  # is populated on a single fresh apply. Match on our endpoint id, never a fixed index.
  value = try(one([
    for pe in data.mongodbatlas_advanced_cluster.this.connection_strings.private_endpoint :
    pe.srv_connection_string
    if contains([for e in pe.endpoints : e.endpoint_id], local.effective_endpoint_id)
  ]), null)
  sensitive = true
}

output "source_db_username" {
  value = mongodbatlas_database_user.source.username
}

output "source_db_password" {
  value     = random_password.source.result
  sensitive = true
}

output "full_db_username" {
  value = mongodbatlas_database_user.full.username
}

output "full_db_password" {
  value     = random_password.full.result
  sensitive = true
}

output "vpc_endpoint_id" {
  description = "AWS interface endpoint ID for the Atlas private endpoint (this instance's own, or the shared regional one it was told to reuse)."
  value       = local.effective_endpoint_id
}

output "vpc_endpoint_dns" {
  description = "DNS entries of the interface endpoint — only populated for the instance that creates it (null when reusing a shared endpoint)."
  value       = var.create_private_endpoint ? aws_vpc_endpoint.atlas[0].dns_entry : null
}

output "api_db_username" {
  value = mongodbatlas_database_user.api.username
}

output "api_db_password" {
  description = "Generated password for the least-privilege API storage user."
  value       = random_password.api.result
  sensitive   = true
}
