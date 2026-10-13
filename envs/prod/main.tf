provider "aws" {
  region = "us-east-1"

  # Safety net: Terraform refuses to run if the credentials belong to any
  # other account (e.g. a work account picked up by mistake from AWS_PROFILE).
  allowed_account_ids = [var.aws_account_id]
}

module "vpc" {
  source = "../../modules/vpc"

  project     = "jv"
  environment = "prod"

  vpc_cidr           = "10.30.0.0/16"
  azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
  single_nat_gateway = false

  tags = {
    Owner      = "john-vega"
    CostCenter = "lab"
  }
}
