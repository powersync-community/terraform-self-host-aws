output "address" {
  description = "RDS endpoint hostname (no port)."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "endpoint" {
  description = "host:port endpoint."
  value       = aws_db_instance.this.endpoint
}

output "source_db_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_password" {
  value     = random_password.master.result
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.db.id
}

output "instance_id" {
  value = aws_db_instance.this.identifier
}
