# Unit tests for the VPC module.
#
# They run with a MOCK AWS provider: no credentials, no AWS calls, no cost.
# Run them from modules/vpc:   terraform init -backend=false && terraform test
#
# What they prove: naming, CIDR layout, NAT topology, endpoint wiring,
# optional features and input validation. What they do NOT prove: that AWS
# accepts the request and traffic really flows (that is what e2e/aws/ is for).

mock_provider "aws" {
  # Data sources the module reads from the provider. Mocks would otherwise
  # return random strings, which breaks region-based naming and ARNs.
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Real ARN shapes: the provider validates ARN arguments even with mocks
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111111111111:log-group:mock"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock"
    }
  }
}

# Baseline inputs (dev-like). Individual runs override what they test.
variables {
  project            = "jv"
  environment        = "dev"
  vpc_cidr           = "10.10.0.0/16"
  azs                = ["us-east-1a", "us-east-1b"]
  single_nat_gateway = true
}

# --- Naming and tagging --------------------------------------------------------

run "naming_follows_convention" {
  command = plan

  assert {
    condition     = output.name == "jv-dev-use1"
    error_message = "Base name must be <project>-<env>-<region_short>."
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "jv-dev-use1-vpc"
    error_message = "VPC Name tag does not follow the convention."
  }

  assert {
    condition     = aws_subnet.private["us-east-1a"].tags["Name"] == "jv-dev-use1-private-a"
    error_message = "Private subnet Name tag must end with the AZ letter."
  }
}

run "mandatory_tags_cannot_be_overridden" {
  command = plan

  variables {
    tags = {
      Owner       = "someone"
      Environment = "prod" # must be ignored: the module sets Environment itself
      ManagedBy   = "clickops"
    }
  }

  assert {
    condition     = aws_vpc.this.tags["Environment"] == "dev" && aws_vpc.this.tags["ManagedBy"] == "terraform"
    error_message = "Caller tags overrode a mandatory tag."
  }

  assert {
    condition     = aws_vpc.this.tags["Owner"] == "someone"
    error_message = "Extra caller tags must be kept."
  }
}

# --- Addressing ----------------------------------------------------------------

run "subnet_cidr_layout" {
  command = plan

  assert {
    condition     = aws_subnet.private["us-east-1a"].cidr_block == "10.10.0.0/19" && aws_subnet.private["us-east-1b"].cidr_block == "10.10.32.0/19"
    error_message = "Private subnets must be /19 blocks starting at the bottom of the VPC."
  }

  assert {
    condition     = aws_subnet.public["us-east-1a"].cidr_block == "10.10.192.0/22" && aws_subnet.public["us-east-1b"].cidr_block == "10.10.196.0/22"
    error_message = "Public subnets must be /22 blocks starting at .192."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs."
  }
}

run "cidr_is_stable_when_az_list_changes" {
  # Removing 1a and reordering must not change the CIDR of 1b or 1c,
  # otherwise Terraform would destroy and recreate those subnets.
  command = plan

  variables {
    azs = ["us-east-1c", "us-east-1b"]
  }

  assert {
    condition     = aws_subnet.private["us-east-1b"].cidr_block == "10.10.32.0/19"
    error_message = "The CIDR of us-east-1b changed when the AZ list changed."
  }

  assert {
    condition     = aws_subnet.private["us-east-1c"].cidr_block == "10.10.64.0/19"
    error_message = "us-east-1c must always get the third /19 block."
  }
}

# --- NAT topology --------------------------------------------------------------

run "single_nat_gateway_is_shared" {
  command = apply

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "single_nat_gateway = true must create exactly one NAT and one EIP."
  }

  assert {
    condition     = alltrue([for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this["us-east-1a"].id])
    error_message = "Every private route table must point to the NAT in the first AZ."
  }

  assert {
    condition     = length(aws_route_table.private) == 2
    error_message = "Each AZ must keep its own private route table even in single-NAT mode."
  }
}

run "one_nat_per_az" {
  command = apply

  variables {
    environment        = "prod"
    vpc_cidr           = "10.30.0.0/16"
    azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "single_nat_gateway = false must create one NAT per AZ."
  }

  assert {
    condition     = alltrue([for az, r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this[az].id])
    error_message = "Each private route table must use the NAT in its own AZ."
  }

  assert {
    condition     = alltrue([for az, n in aws_nat_gateway.this : n.subnet_id == aws_subnet.public[az].id])
    error_message = "NAT gateways must live in the public subnet of their AZ."
  }
}

# --- VPC endpoints -------------------------------------------------------------

run "endpoints_default" {
  command = apply

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 must use a Gateway endpoint in the provider region."
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3.route_table_ids) == 2
    error_message = "The S3 endpoint must be attached to every private route table."
  }

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr"])
    error_message = "ECR api and dkr Interface endpoints must be created by default."
  }

  assert {
    condition     = alltrue([for ep in aws_vpc_endpoint.interface : ep.private_dns_enabled])
    error_message = "Interface endpoints need private DNS so the public ECR hostnames resolve privately."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.endpoints_https[0].from_port == 443 && aws_vpc_security_group_ingress_rule.endpoints_https[0].cidr_ipv4 == "10.10.0.0/16"
    error_message = "Endpoint SG must only allow HTTPS from the VPC CIDR."
  }
}

run "no_interface_endpoints" {
  command = plan

  variables {
    interface_endpoints = []
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0 && length(aws_security_group.endpoints) == 0
    error_message = "With no interface endpoints, neither endpoints nor their SG must be created."
  }
}

# --- Flow logs -----------------------------------------------------------------

run "flow_logs_enabled_by_default" {
  command = plan

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL" && aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 30
    error_message = "Flow logs must capture ALL traffic with a finite retention."
  }
}

run "flow_logs_disabled" {
  command = plan

  variables {
    enable_flow_logs = false
  }

  assert {
    condition     = length(aws_flow_log.this) == 0 && length(aws_iam_role.flow_logs) == 0 && length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "enable_flow_logs = false must not create any flow-log resource."
  }
}

# --- Input validation ----------------------------------------------------------

run "rejects_bad_project" {
  command = plan

  variables {
    project = "My-Project"
  }

  expect_failures = [var.project]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "rejects_too_small_vpc" {
  command = plan

  variables {
    vpc_cidr = "10.10.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_single_az" {
  command = plan

  variables {
    azs = ["us-east-1a"]
  }

  expect_failures = [var.azs]
}

run "rejects_duplicate_azs" {
  command = plan

  variables {
    azs = ["us-east-1a", "us-east-1a"]
  }

  expect_failures = [var.azs]
}

run "iam_role_name_prefix_applied" {
  command = plan

  variables {
    iam_role_name_prefix = "team-a-"
  }

  assert {
    condition     = aws_iam_role.flow_logs[0].name == "team-a-jv-dev-use1-vpc-flow-logs"
    error_message = "iam_role_name_prefix must be prepended to the Flow Logs role name."
  }
}

run "iam_role_name_prefix_rejects_invalid" {
  command = plan

  variables {
    iam_role_name_prefix = "bad prefix!"
  }

  expect_failures = [var.iam_role_name_prefix]
}
