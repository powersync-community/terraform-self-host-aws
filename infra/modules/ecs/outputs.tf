output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "replication_service_name" {
  value = aws_ecs_service.replication.name
}

output "compact_task_family" {
  value = aws_ecs_task_definition.compact.family
}

output "log_group_names" {
  value = [
    aws_cloudwatch_log_group.replication.name,
    aws_cloudwatch_log_group.api.name,
    aws_cloudwatch_log_group.api_cwagent.name,
    aws_cloudwatch_log_group.api_prometheus.name,
    aws_cloudwatch_log_group.compact.name,
  ]
}
