resource "aws_ecr_repository" "demo" {
  name                 = "${var.project}/demo"
  image_tag_mutability = "MUTABLE" # fine for dev; use IMMUTABLE for prod

  image_scanning_configuration {
    scan_on_push = true # free vulnerability scan on each push
  }

  # dev convenience: allow `terraform destroy` to delete the repo even if it
  # still has images in it. In prod you'd leave this false.
  force_delete = true
}

# Keep only the last few images so old builds don't pile up
resource "aws_ecr_lifecycle_policy" "demo" {
  repository = aws_ecr_repository.demo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value = aws_ecr_repository.demo.repository_url
}