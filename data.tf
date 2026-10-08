# ===========================================================================
# Data tier (free-plan friendly):
#   - Postgres runs as an ECS Fargate task (NO RDS -> nothing the free plan blocks)
#   - Redis stays on ElastiCache (allowed on the free plan, already created)
# Postgres is reachable at a stable DNS name via AWS Cloud Map service discovery.
# ===========================================================================

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "postgres" {
  name        = "${local.name}-postgres-sg"
  description = "Postgres task - allow 5432 from the app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # needs outbound (via NAT) to pull the postgres image
  }

  tags = { Name = "${local.name}-postgres-sg" }
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis-sg"
  description = "ElastiCache - allow 6379 from the app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from app"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = { Name = "${local.name}-redis-sg" }
}

# ---------------------------------------------------------------------------
# Random DB password -- stored only in the binbon/db secret (support.tf).
# Neither task definition contains it.
# ---------------------------------------------------------------------------
locals {
  db_name = "binbon"
  db_user = "binbon_admin"
}

resource "random_password" "db" {
  length  = 20
  special = false
}

# ---------------------------------------------------------------------------
# Service discovery: a private DNS name for the Postgres task.
# The app connects to "postgres.binbon.local" instead of a changing IP.
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "binbon.local"
  description = "internal service discovery"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "postgres" {
  name = "postgres"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# ---------------------------------------------------------------------------
# Postgres as a Fargate task.
# Data lives in the container (no volume): it survives while the task runs and
# resets if the task restarts -- fine for a same-day dev environment.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "postgres" {
  family                   = "${local.name}-postgres"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "postgres"
      image        = "postgres:16"
      essential    = true
      portMappings = [{ containerPort = 5432, protocol = "tcp" }]

      environment = [
        { name = "POSTGRES_DB", value = local.db_name },
        { name = "POSTGRES_USER", value = local.db_user },
      ]

      # Injected by the ECS agent (execution role) from Secrets Manager at task
      # start -- the task definition only holds the secret's ARN + JSON key.
      secrets = [
        { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.demo.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "postgres"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "postgres" {
  name            = "${local.name}-postgres"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.postgres.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id # app subnets have NAT to pull the image
    security_groups  = [aws_security_group.postgres.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.postgres.arn
  }

  # the secret must hold a value before the task tries to read it
  depends_on = [aws_secretsmanager_secret_version.db]
}

# ---------------------------------------------------------------------------
# ElastiCache - single Redis node (already created; unchanged)
# ---------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name}-cache-subnets"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${local.name}-redis"
  engine               = "redis"
  node_type            = "cache.t4g.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "db_host" {
  value = "${aws_service_discovery_service.postgres.name}.${aws_service_discovery_private_dns_namespace.main.name}"
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}
