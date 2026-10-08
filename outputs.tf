output "vpc_id" {
  description = "The VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnets (ALB, NAT)"
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "App-private subnets (Fargate)"
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "Data-private subnets (RDS, ElastiCache, OpenSearch)"
  value       = aws_subnet.data[*].id
}
