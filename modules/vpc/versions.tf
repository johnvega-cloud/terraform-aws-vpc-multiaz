# Version constraints for the reusable VPC module.
#
# Why ranges here and exact pins elsewhere:
# - A reusable MODULE declares the widest range it is known to work with,
#   so callers are not forced onto one exact provider version.
# - Each ROOT configuration (envs/<env>) pins the exact provider build via its
#   committed .terraform.lock.hcl file.

terraform {
  # 1.7+ is required for `terraform test` with mock providers (used in tests/).
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}
