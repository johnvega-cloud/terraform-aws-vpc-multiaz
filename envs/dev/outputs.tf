output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, for workloads (EKS, RDS...)."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs, for internet-facing load balancers."
  value       = module.vpc.public_subnet_ids
}

output "nat_public_ips" {
  description = "Public egress IPs of the NAT gateways (for third-party allow-lists)."
  value       = module.vpc.nat_public_ips
}
