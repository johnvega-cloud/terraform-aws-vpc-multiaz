# What other stacks (EKS, RDS, ALB...) need from this network.
# Maps are keyed by AZ name so consumers can pick a specific AZ;
# lists are provided for resources that just want "all private subnets".

output "name" {
  description = "Base name used for every resource: <project>-<env>-<region>."
  value       = local.name
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZs the VPC spans."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (list), for internet-facing load balancers."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (list), for EKS node groups, RDS subnet groups, etc."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "public_subnets_by_az" {
  description = "Map AZ => public subnet {id, cidr}."
  value       = { for az, s in aws_subnet.public : az => { id = s.id, cidr = s.cidr_block } }
}

output "private_subnets_by_az" {
  description = "Map AZ => private subnet {id, cidr}."
  value       = { for az, s in aws_subnet.private : az => { id = s.id, cidr = s.cidr_block } }
}

output "private_route_table_ids" {
  description = "Private route table IDs (e.g. to add Transit Gateway routes from another module)."
  value       = [for az in var.azs : aws_route_table.private[az].id]
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateways (what third parties see; useful for IP allow-lists)."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}

output "s3_endpoint_id" {
  description = "ID of the S3 Gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "Map service => Interface endpoint ID."
  value       = { for svc, ep in aws_vpc_endpoint.interface : svc => ep.id }
}

output "endpoints_security_group_id" {
  description = "Security group attached to the Interface endpoints (null if none)."
  value       = one(aws_security_group.endpoints[*].id)
}

output "flow_logs_log_group_name" {
  description = "CloudWatch Logs group receiving VPC Flow Logs (null if disabled)."
  value       = one(aws_cloudwatch_log_group.flow_logs[*].name)
}
