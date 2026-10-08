# ---------------------------------------------------------------------------
# S3 bucket (the demo app's /upload, /download, /s3 endpoints)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "demo" {
  bucket = "${var.project}-demo-${data.aws_caller_identity.current.account_id}"

  # dev convenience: let `terraform destroy` empty + delete it
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3, your earlier choice
    }
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager -- DB credentials, the single source of truth for both:
#   - the Postgres task (ECS injects "password" as POSTGRES_PASSWORD at start)
#   - the app (reads the whole secret at runtime via DB_SECRET_ARN)
# The password is generated once by random_password and is stable across
# applies; it only changes on destroy/recreate (together with the DB itself).
# Do NOT enable automatic rotation: it would change the secret but not the
# password inside Postgres.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project}/db"
  recovery_window_in_days = 0 # dev: delete immediately, so destroy -> up can reuse the name
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = local.db_user
    password = random_password.db.result
  })
}

# ---------------------------------------------------------------------------
# CloudWatch log group for the Fargate service
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "demo" {
  name              = "/ecs/${var.project}-demo"
  retention_in_days = 7 # never leave logs on "never expire" -- cost leak
}

# account id, used to make the bucket name globally unique
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "s3_bucket_name" {
  value = aws_s3_bucket.demo.id
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.demo.name
}