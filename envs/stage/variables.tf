variable "aws_account_id" {
  description = "The ONLY AWS account this environment may be deployed to. Set it in terraform.tfvars (git-ignored) or TF_VAR_aws_account_id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}
