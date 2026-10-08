provider "aws" {
  region = var.region

  # default_tags is applied automatically to every taggable resource --
  # so you never hand-tag each one, and everything is easy to find and clean up.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "random" {
  
}