# ===========================================================================
# Compute + edge: ALB -> Fargate service running the demo image
# ===========================================================================

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB - allow HTTP from the internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "Fargate app - allow 8000 from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "app port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # outbound to DB, Redis, ECR, Secrets, S3
  }

  tags = { Name = "${local.name}-app-sg" }
}

# ---------------------------------------------------------------------------
# Application Load Balancer (public subnets) + target group + HTTP listener
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-tg"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip" # Fargate tasks register by IP
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/health" # dependency-free, so tasks go healthy fast
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# ECS cluster + task definition + service
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-demo"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # matches the amd64 image you pushed
  }

  container_definitions = jsonencode([
    {
      name         = "demo"
      image        = "${aws_ecr_repository.demo.repository_url}:v1"
      essential    = true
      portMappings = [{ containerPort = 8000, protocol = "tcp" }]

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "DB_HOST", value = "${aws_service_discovery_service.postgres.name}.${aws_service_discovery_private_dns_namespace.main.name}" },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = local.db_name },
        # username + password are read by the app at runtime (task role)
        { name = "DB_SECRET_ARN", value = aws_secretsmanager_secret.db.arn },
        { name = "REDIS_HOST", value = aws_elasticache_cluster.redis.cache_nodes[0].address },
        { name = "REDIS_PORT", value = "6379" },
        { name = "REDIS_TLS", value = "false" },
        { name = "S3_BUCKET", value = aws_s3_bucket.demo.id },
        # COOKIE_SECURE stays unset (false): the ALB only serves HTTP
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.demo.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "${local.name}-demo"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false # private subnet; reaches out via NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "demo"
    container_port   = 8000
  }

  health_check_grace_period_seconds = 60

  # After bootstrap, GitHub Actions registers new task-definition revisions
  # (new image tags) and points the service at them. Without this, the next
  # `terraform apply` would roll the service back to Terraform's revision.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http, aws_secretsmanager_secret_version.db]
}

# ---------------------------------------------------------------------------
# The URL you'll curl
# ---------------------------------------------------------------------------
output "alb_dns_name" {
  value = aws_lb.main.dns_name
}
