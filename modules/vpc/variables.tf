# Inputs of the VPC module. Every «var» in the architecture diagram lives here.
#
# Note: there is NO `region` variable on purpose. A reusable module never
# configures its own provider; it inherits the AWS provider (and therefore the
# region) from the root configuration that calls it (envs/<env>/).

# --- Naming -------------------------------------------------------------------

variable "project" {
  description = "Short project code, first part of every resource name: <project>-<env>-<region>-<resource>. Keep it short (2-6 chars): some AWS names are limited to 32 chars."
  type        = string
  # No default on purpose: a reusable module must not ship a personal/company value.

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.project))
    error_message = "project must be 2-6 chars, lowercase letters or digits, starting with a letter (e.g. \"jv\")."
  }
}

variable "environment" {
  description = "Environment this VPC belongs to. One VPC per environment."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

# --- Addressing ---------------------------------------------------------------

variable "vpc_cidr" {
  description = "IPv4 CIDR of the VPC. Must not overlap with other environments (dev 10.10/16, stage 10.20/16, prod 10.30/16)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /20 (AWS allows /16 to /28; below /20 subnets get too small for EKS)."
  }
}

variable "azs" {
  description = "Availability Zone names to spread the VPC across, e.g. [\"us-east-1a\", \"us-east-1b\"]. Order matters: index 0 hosts the shared NAT when single_nat_gateway = true."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 4
    error_message = "azs must contain 2 to 4 AZs (ALB, EKS and RDS subnet groups require at least 2)."
  }

  validation {
    condition     = length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must not contain duplicates."
  }
}

# --- Egress -------------------------------------------------------------------

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper, cross-AZ dependency; dev/stage). false = one NAT per AZ (resilient; prod)."
  type        = bool
  default     = false # secure-by-default: callers must opt in to the cheaper, less resilient option
}

# --- VPC endpoints ------------------------------------------------------------

variable "interface_endpoints" {
  description = "AWS service short names that get an Interface VPC endpoint (one ENI per AZ, billed hourly). The S3 Gateway endpoint is always created (free)."
  type        = set(string)
  default     = ["ecr.api", "ecr.dkr"]

  validation {
    condition     = alltrue([for s in var.interface_endpoints : can(regex("^[a-z0-9][a-z0-9.-]*$", s))])
    error_message = "Each interface endpoint must be a service short name like \"ecr.api\", \"sts\" or \"logs\"."
  }
}

# --- Observability ------------------------------------------------------------

variable "enable_flow_logs" {
  description = "Send VPC Flow Logs (who talked to whom) to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "Days to keep Flow Logs in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a value accepted by CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, ...)."
  }
}

# --- Tagging ------------------------------------------------------------------

variable "tags" {
  description = "Extra tags merged into every resource (e.g. owner, cost-center). Environment and ManagedBy are added automatically."
  type        = map(string)
  default     = {}
}
