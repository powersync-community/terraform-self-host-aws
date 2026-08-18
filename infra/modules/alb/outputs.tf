output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "alb_dns" {
  value = aws_lb.this.dns_name
}

output "alb_arn" {
  value = aws_lb.this.arn
}

# CloudWatch dimension values (LoadBalancer / TargetGroup) for alarms.
output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.this.arn_suffix
}

output "certificate_arn" {
  value = aws_acm_certificate.this.arn
}
