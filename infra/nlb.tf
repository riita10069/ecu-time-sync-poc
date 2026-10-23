# 公開 NLB: 車両からの NTS 付き NTP (UDP 123)。cross-zone 有効。全タスクがマスター鍵を共有するので、どのタスクに届いてもよい
resource "aws_lb" "public" {
  name                             = "${var.name}-ntp"
  load_balancer_type               = "network"
  internal                         = false
  subnets                          = [for s in aws_subnet.public : s.id]
  security_groups                  = [aws_security_group.public_nlb.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "ntp" {
  name                 = "${var.name}-ntp"
  port                 = 123
  protocol             = "UDP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30
  # UDP はヘルスチェックできないので、タスク内のディープヘルスチェック (HTTP 8080) を使う
  health_check {
    protocol            = "HTTP"
    port                = "8080"
    path                = "/health"
    interval            = 5
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ntp" {
  load_balancer_arn = aws_lb.public.arn
  port              = 123
  protocol          = "UDP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ntp.arn
  }
}

# 内部 NLB: Lambda からの NTS-KE (TCP 4460)。TLS は ntpd-rs で終端するので TCP で素通しする
resource "aws_lb" "internal" {
  name                             = "${var.name}-ke"
  load_balancer_type               = "network"
  internal                         = true
  subnets                          = [for s in aws_subnet.private : s.id]
  security_groups                  = [aws_security_group.internal_nlb.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "ke" {
  name                 = "${var.name}-ke"
  port                 = 4460
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30
  health_check {
    protocol            = "HTTP"
    port                = "8080"
    path                = "/health"
    interval            = 5
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ke" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 4460
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ke.arn
  }
}
