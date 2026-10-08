# ===========================================================================
# CI/CD: GitHub Actions -> AWS via OIDC (no access keys stored in GitHub).
# The binbon-demo workflow assumes this role to push images to ECR and roll
# the ECS app service onto a new task-definition revision.
# ===========================================================================

variable "github_repo" {
  description = "owner/name of the app repo allowed to deploy"
  type        = string
  default     = "mostafasaleh97/binbon-demo"
}

# GitHub's OIDC "sub" claim embeds immutable IDs: repo:owner@<owner_id>/name@<repo_id>:...
# so a deleted-and-recreated repo with the same name can't assume the role.
# Look them up with: curl -s https://api.github.com/repos/<owner>/<name>
variable "github_owner_id" {
  description = "numeric GitHub user/org ID of the repo owner"
  type        = string
  default     = "118595619"
}

variable "github_repo_id" {
  description = "numeric GitHub repository ID"
  type        = string
  default     = "1410099885"
}

variable "github_branch" {
  description = "only workflows running on this branch may assume the role"
  type        = string
  default     = "main"
}

locals {
  github_owner     = split("/", var.github_repo)[0]
  github_repo_name = split("/", var.github_repo)[1]
}

# One per account; GitHub's token issuer. No thumbprint needed on AWS provider v6.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # only this repo, only this branch
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo_name}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

data "aws_iam_policy_document" "github_actions" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"] # account-wide by design
    resources = ["*"]
  }

  statement {
    sid = "EcrPushThisRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.demo.arn]
  }

  statement {
    sid       = "TaskDefinitions" # these actions don't support resource scoping
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "DeployAppService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [aws_ecs_service.app.id]
  }

  # registering a task definition that uses these roles requires passing them
  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.name}-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
