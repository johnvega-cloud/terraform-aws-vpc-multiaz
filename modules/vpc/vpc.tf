# VPC, Internet Gateway and subnets.
#
# Subnet CIDR layout (example for 10.10.0.0/16):
#
#   10.10.0.0   - 10.10.191.255   private subnets  /19 each  (newbits=3, netnum = AZ letter a..f -> 0..5)
#   10.10.192.0 - 10.10.215.255   public subnets   /22 each  (newbits=6, netnum = 48 + AZ letter)
#   10.10.216.0 - 10.10.255.255   free, reserved for future tiers (e.g. database subnets)
#
# Why the CIDR is derived from the AZ LETTER and not from the position in var.azs:
# if it came from the list position, removing "us-east-1a" would shift "1b" to
# position 0, its CIDR would change, and Terraform would destroy and recreate
# the subnet (and everything inside it). With the letter, each AZ always gets
# the same CIDR no matter how the list is ordered or edited.
#
# Private subnets are big because workloads live there (EKS gives every pod its
# own VPC IP). Public subnets only host load balancers and NAT gateways.

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required for Interface VPC endpoints with private DNS:
  # ecr.api / ecr.dkr resolve to the endpoint ENIs instead of public IPs.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name}-vpc" })
}

# Lock down the default security group AWS creates with every VPC
# (by default it allows all traffic between its members). No rules = deny all.
# CIS AWS Foundations Benchmark: "the default security group restricts all traffic".
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-default-sg-do-not-use" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-igw" })
}

# for_each keyed by AZ name (not count): each subnet's identity in the state is
# its AZ, so adding or removing one AZ never touches the subnets of the others.

resource "aws_subnet" "public" {
  for_each = toset(var.azs)

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 6, 48 + local.az_index[each.key])

  # Nothing launched here gets a public IP automatically. ALBs and NAT gateways
  # get their public addresses explicitly (EIP / AWS-managed).
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = "${local.name}-public-${local.az_suffix[each.key]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1" # lets the AWS Load Balancer Controller find public subnets
  })
}

resource "aws_subnet" "private" {
  for_each = toset(var.azs)

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, local.az_index[each.key])

  tags = merge(local.tags, {
    Name                              = "${local.name}-private-${local.az_suffix[each.key]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1" # internal load balancers for EKS
  })
}
