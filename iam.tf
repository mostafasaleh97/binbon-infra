# ---------------------------------------------------------------------------
# Trust policy: both roles are assumed by ECS tasks
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role -- pulls the image, writes logs
# ---------------------------------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# AWS-managed policy that grants ECR pull + CloudWatch Logs write
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lets the ECS agent read the DB secret at task start, to inject
# POSTGRES_PASSWORD into the Postgres container. Containers never see these
# credentials -- only the agent uses the execution role.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.name}-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---------------------------------------------------------------------------
# Task role -- what the app container itself is allowed to do (S3 + Secrets).
# Attached ONLY to the app task definition; the Postgres task has no task
# role, so it has no AWS permissions at all.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Scoped to the exact bucket and secret this app uses.
data "aws_iam_policy_document" "task" {
  statement {
    sid       = "S3ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"] # also what HeadBucket (status page) needs
    resources = [aws_s3_bucket.demo.arn]
  }

  statement {
    sid    = "S3Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # "Delete" button on a photo
    ]
    resources = ["${aws_s3_bucket.demo.arn}/*"]
  }

  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.name}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ---------------------------------------------------------------------------
# Outputs (the ECS task definition will reference these)
# ---------------------------------------------------------------------------
output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}