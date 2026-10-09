# Naming and tagging conventions, computed once and reused by every resource.

data "aws_region" "current" {}

locals {
  # us-east-1 -> use1 · eu-west-2 -> euw2 · ap-southeast-1 -> aps1 · us-gov-west-1 -> usgw1
  region_parts = split("-", data.aws_region.current.region)
  region_short = format(
    "%s%s%s",
    local.region_parts[0],
    join("", [for p in slice(local.region_parts, 1, length(local.region_parts) - 1) : substr(p, 0, 1)]),
    local.region_parts[length(local.region_parts) - 1],
  )

  # Base for every Name tag: <project>-<env>-<region>
  name = "${var.project}-${var.environment}-${local.region_short}"

  # Last letter of each AZ: us-east-1a -> a (used as name suffix: jv-dev-use1-private-a)
  az_suffix = { for az in var.azs : az => substr(az, length(az) - 1, 1) }

  # Stable numeric index per AZ, from its letter: a=0, b=1 ... f=5 (drives subnet CIDRs)
  az_index = { for az, letter in local.az_suffix : az => index(["a", "b", "c", "d", "e", "f"], letter) }

  # Mandatory tags go LAST in merge() so caller-supplied tags cannot override them.
  tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "terraform-aws-vpc-multiaz"
  })
}
