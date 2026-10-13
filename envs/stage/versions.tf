terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # root config: the exact build is pinned by .terraform.lock.hcl
    }
  }

  # State: local for the lab (one person, short-lived environments).
  # For a team, switch to the S3 backend with native locking (Terraform >= 1.10):
  #
  # backend "s3" {
  #   bucket       = "<state-bucket>"
  #   key          = "terraform-aws-vpc-multiaz/stage/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
