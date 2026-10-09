# VPC endpoints: keep traffic to AWS services on the AWS network instead of
# sending it through the NAT gateway (cheaper, and it never touches the internet).
#
#   S3   -> Gateway endpoint: free, implemented as a route in each private route table.
#   ECR  -> Interface endpoints (ecr.api, ecr.dkr): one ENI per private subnet, billed hourly.
#
# Gotcha: ECR stores image LAYERS in S3. With only ecr.api + ecr.dkr and no S3
# endpoint, `docker pull` still downloads the layers through the NAT.

# --- S3 Gateway endpoint (always created) -------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Adds an S3 prefix-list route to every private route table
  route_table_ids = [for rt in aws_route_table.private : rt.id]

  tags = merge(local.tags, { Name = "${local.name}-vpce-s3" })
}

# --- Security group for Interface endpoints ------------------------------------
# Only HTTPS (443) from inside the VPC. Security groups are stateful: responses
# are allowed back automatically, so no egress rule is needed.

resource "aws_security_group" "endpoints" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  name        = "${local.name}-sg-vpce"
  description = "HTTPS from inside the VPC to Interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-sg-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = length(var.interface_endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from the VPC CIDR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

# --- Interface endpoints (ecr.api, ecr.dkr by default) -------------------------

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [for s in aws_subnet.private : s.id] # one ENI per AZ
  security_group_ids = [aws_security_group.endpoints[0].id]

  # The service's public DNS name (e.g. api.ecr.us-east-1.amazonaws.com)
  # resolves to the endpoint's private IPs from inside the VPC. Requires
  # enable_dns_support + enable_dns_hostnames on the VPC.
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-vpce-${replace(each.key, ".", "-")}" })
}
