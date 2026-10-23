resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "main" {
  name = var.name
}

# --- ECS Managed Instances の IAM ---
data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "infrastructure" {
  name               = "ecsInfrastructureRole-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

resource "aws_iam_role_policy_attachment" "infrastructure" {
  role       = aws_iam_role.infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# マネージドポリシーの PassRole が ecsInstanceRole* に限られるので、名前はこの接頭辞で始める
resource "aws_iam_role" "instance" {
  name               = "ecsInstanceRole-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "instance" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInstanceRolePolicyForManagedInstances"
}

resource "aws_iam_instance_profile" "instance" {
  name = "ecsInstanceRole-${var.name}"
  role = aws_iam_role.instance.name
}

resource "aws_ecs_capacity_provider" "mi" {
  name    = "${var.name}-mi"
  cluster = aws_ecs_cluster.main.name
  managed_instances_provider {
    infrastructure_role_arn = aws_iam_role.infrastructure.arn
    propagate_tags          = "CAPACITY_PROVIDER"
    instance_launch_template {
      ec2_instance_profile_arn = aws_iam_instance_profile.instance.arn
      monitoring               = "BASIC"
      network_configuration {
        subnets         = [for s in aws_subnet.private : s.id]
        security_groups = [aws_security_group.instances.id]
      }
      storage_configuration {
        storage_size_gib = 30
      }
      instance_requirements {
        allowed_instance_types = var.instance_types
        vcpu_count {
          min = 2
        }
        memory_mib {
          min = 4096
        }
      }
    }
  }
  depends_on = [aws_iam_role_policy_attachment.infrastructure, aws_iam_role_policy_attachment.instance]
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.mi.name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.mi.name
    weight            = 1
  }
}

# --- タスクの IAM ---
data "aws_iam_policy_document" "assume_task" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.pool_token.arn, aws_secretsmanager_secret.keyset.arn,
      aws_secretsmanager_secret.ke_cert.arn, aws_secretsmanager_secret.ke_key.arn]
    }]
  })
}

# ECS Exec 用
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
}

resource "aws_iam_role_policy" "task_exec" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
      Resource = "*"
    }]
  })
}

locals {
  image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  log = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.app.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "task"
    }
  }
}

resource "aws_ecs_task_definition" "time" {
  family                   = var.name
  requires_compatibilities = ["MANAGED_INSTANCES"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([
    {
      name             = "ntpd-rs"
      image            = local.image
      essential        = true
      command          = ["/poc/scripts/ntpd-rs-entrypoint.sh"]
      logConfiguration = local.log
      portMappings = [
        { containerPort = 123, protocol = "udp" },
        { containerPort = 4460, protocol = "tcp" },
      ]
      secrets = [
        { name = "POOL_TOKEN", valueFrom = aws_secretsmanager_secret.pool_token.arn },
        { name = "NTPD_KEYSET_B64", valueFrom = aws_secretsmanager_secret.keyset.arn },
        { name = "NTS_CERT_PEM", valueFrom = aws_secretsmanager_secret.ke_cert.arn },
        { name = "NTS_KEY_PEM", valueFrom = aws_secretsmanager_secret.ke_key.arn },
      ]
    },
    {
      name             = "chrony"
      image            = local.image
      essential        = true
      command          = ["/poc/scripts/chrony-entrypoint.sh"]
      logConfiguration = local.log
      linuxParameters = var.enable_phc ? {
        devices = [{ hostPath = var.phc_host_path, containerPath = "/dev/ptp0", permissions = ["read", "write"] }]
      } : null
    },
    {
      name             = "health"
      image            = local.image
      essential        = true
      command          = ["python3", "/poc/app/healthcheck.py"]
      logConfiguration = local.log
      portMappings     = [{ containerPort = 8080, protocol = "tcp" }]
      environment = [
        { name = "BIND", value = "0.0.0.0" }, # タスク ENI。セキュリティグループで NLB からのみ許可
        { name = "MAX_OFFSET_MS", value = tostring(var.max_offset_ms) },
        { name = "NTPD_CHECK", value = "127.0.0.1" },
        { name = "LOG_INTERVAL", value = "60" },
      ]
    },
  ])
}

resource "aws_ecs_service" "time" {
  name                              = var.name
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.time.arn
  desired_count                     = var.desired_count
  enable_execute_command            = true
  health_check_grace_period_seconds = 120
  # ローリングデプロイでは新しいタスクが healthy になってから古いタスクを外す
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.mi.name
    weight            = 1
  }
  network_configuration {
    subnets         = [for s in aws_subnet.private : s.id]
    security_groups = [aws_security_group.task.id]
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.ntp.arn
    container_name   = "ntpd-rs"
    container_port   = 123
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.ke.arn
    container_name   = "ntpd-rs"
    container_port   = 4460
  }
  depends_on = [aws_lb_listener.ntp, aws_lb_listener.ke, aws_ecs_cluster_capacity_providers.main]
}
