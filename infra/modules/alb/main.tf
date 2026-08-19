###############################################################################
# ACM certificate with automated DNS validation (Terraform owns the zone records)
###############################################################################

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

###############################################################################
# Application Load Balancer
###############################################################################

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_sg_id]

  # Long-lived sync websockets: raise well above the 60s default.
  idle_timeout = var.idle_timeout

  # Demo: no deletion protection so destroy is immediate. Enable it for production.
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name_prefix}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Long-lived streams: spread new connections to the least-loaded target.
  load_balancing_algorithm_type = "least_outstanding_requests"

  # Allow active syncs to drain on scale-in before forced close.
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = "/probes/liveness"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

###############################################################################
# Static JWKS: served directly off the ALB at /api/auth/keys (fixed-response).
# Body is the public RS256 JWK generated in-Terraform (auth.tf, via the jwks provider); the
# matching private key lives in Secrets Manager and example-client mints client JWTs locally.
# PowerSync fetches this URL as its jwks_uri. The JWKS is ~435 bytes; the ALB caps fixed-response
# bodies at 1024, so only one key fits; rotating the key means re-running apply.
###############################################################################

resource "aws_lb_listener_rule" "jwks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api/auth/keys"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = var.jwks_json
      status_code  = "200"
    }
  }
}

###############################################################################
# Alias A record: domain -> ALB
###############################################################################

resource "aws_route53_record" "alias" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
