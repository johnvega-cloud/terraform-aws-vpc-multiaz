# End-to-end test against a REAL AWS account. It costs money while it is up
# (NAT gateway, 2 Interface endpoints, 1 t3.micro): run it, check, destroy.
# See e2e/aws/README.md for the exact steps.
#
# What it adds on top of the module, only to prove traffic really flows:
#   - a probe instance in a PRIVATE subnet, reached through SSM (no SSH, no public IP)
#   - an S3 bucket whose policy DENIES every request that does not arrive
#     through this VPC's S3 gateway endpoint

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "aws_account_id" {
  description = "Account the test is allowed to run in (guard against the wrong credentials)."
  type        = string
}

variable "region" {
  description = "Region for the test."
  type        = string
  default     = "us-east-1"
}

variable "iam_role_name_prefix" {
  description = "Prefix for every IAM name, for accounts that only allow roles matching a pattern."
  type        = string
  default     = ""
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Purpose = "e2e-test"
      Repo    = "terraform-aws-vpc-multiaz"
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project              = "jv"
  environment          = "dev"
  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["${var.region}a", "${var.region}b"]
  single_nat_gateway   = true
  iam_role_name_prefix = var.iam_role_name_prefix

  tags = {
    Owner      = "john-vega"
    CostCenter = "lab"
  }
}

# --- Probe instance (private subnet, SSM only) ---------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "probe" {
  name               = "${var.iam_role_name_prefix}jv-e2e-probe"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "probe" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.probe.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "probe_bucket" {
  name = "read-e2e-bucket"
  role = aws_iam_role.probe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.vpce_only.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "probe" {
  name = "${var.iam_role_name_prefix}jv-e2e-probe"
  role = aws_iam_role.probe.name
}

resource "aws_security_group" "probe" {
  name        = "jv-e2e-probe"
  description = "Probe instance: no inbound, all outbound"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "probe_all" {
  security_group_id = aws_security_group.probe.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "probe" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.probe.id]
  iam_instance_profile   = aws_iam_instance_profile.probe.name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "jv-e2e-probe" }

  depends_on = [aws_iam_role_policy_attachment.probe]
}

# --- Bucket reachable ONLY through the S3 gateway endpoint ---------------------

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "vpce_only" {
  bucket        = "jv-e2e-vpce-${var.aws_account_id}-${random_id.bucket.hex}"
  force_destroy = true
}

resource "aws_s3_object" "marker" {
  bucket  = aws_s3_bucket.vpce_only.id
  key     = "marker.txt"
  content = "reached-through-vpce"
}

resource "aws_s3_bucket_policy" "vpce_only" {
  bucket = aws_s3_bucket.vpce_only.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyGetOutsideVpce"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.vpce_only.arn}/*"
      Condition = {
        StringNotEquals = { "aws:SourceVpce" = module.vpc.s3_endpoint_id }
      }
    }]
  })

  # The marker is uploaded from outside the VPC, so it must exist before the deny.
  depends_on = [aws_s3_object.marker]
}

# --- Outputs used by the checks in README.md -----------------------------------

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "probe_instance_id" {
  value = aws_instance.probe.id
}

output "bucket" {
  value = aws_s3_bucket.vpce_only.id
}

output "flow_logs_log_group_name" {
  value = module.vpc.flow_logs_log_group_name
}
