provider "aws" {
  region = "us-east-1"

  # Safety net: Terraform refuses to run if the credentials belong to any
  # other account (e.g. a work account picked up by mistake from AWS_PROFILE).
  allowed_account_ids = [var.aws_account_id]
}

module "vpc" {
  source = "../../modules/vpc"

  project     = "jv"
  environment = "stage"

  vpc_cidr           = "10.20.0.0/16"
  azs                = ["us-east-1a", "us-east-1b"]
  single_nat_gateway = true

  tags = {
    Owner      = "john-vega"
    CostCenter = "lab"
  }
}
