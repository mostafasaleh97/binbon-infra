variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-north-1" # where your console work has been; use eu-central-1 to match the design
}

variable "project" {
  description = "Project name, used for resource names and tags"
  type        = string
  default     = "binbon"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many Availability Zones to spread across"
  type        = number
  default     = 2
}
