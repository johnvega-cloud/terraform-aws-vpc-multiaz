# terraform-aws-vpc-multiaz

[![ci](https://github.com/johnvega-cloud/terraform-aws-vpc-multiaz/actions/workflows/ci.yml/badge.svg)](https://github.com/johnvega-cloud/terraform-aws-vpc-multiaz/actions/workflows/ci.yml)

Reusable Terraform module that provisions a **multi-AZ AWS VPC** with public and
private subnets, NAT gateways and VPC endpoints for S3 and ECR, parameterized per
region and environment (dev / stage / prod).

## Problem it solves

Teams that hand-build their own networks end up with overlapping IP ranges,
databases accidentally placed in public subnets, and NAT bills nobody can explain
(for example, container image pulls from ECR going through the NAT and billed per GB).
This module gives one versioned, reviewed network definition that is instantiated
identically in every environment, changing only its inputs.

## Architecture

![VPC architecture](docs/architecture-vpc.svg)

**How to build it, and in what order:** see [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md)
(authoring steps, design decisions, and the provisioning order Terraform follows).

- **One VPC per environment** (ideally one AWS account per environment), with
  non-overlapping CIDRs so they can be connected later (Transit Gateway / peering).
- **Public subnets**: only internet-facing components (load balancers, NAT gateways).
- **Private subnets**: workloads (apps, EKS, RDS). Outbound internet via the NAT
  in the same AZ; no inbound access from the internet.
- **S3 gateway endpoint** (free) and **ECR interface endpoints** (`ecr.api`,
  `ecr.dkr`): traffic to S3/ECR stays on the AWS network instead of the NAT.
  ECR stores image layers in S3, so both are needed to keep `docker pull` off the NAT.
- **VPC Flow Logs** to CloudWatch Logs, written by a least-privilege IAM role.

| Environment | CIDR | AZs | NAT gateways | Flow-log retention |
|---|---|---|---|---|
| dev   | 10.10.0.0/16 | 2 | 1 (shared, lower cost) | 30 days |
| stage | 10.20.0.0/16 | 2 | 1 (shared) | 30 days |
| prod  | 10.30.0.0/16 | 3 | 1 per AZ (no cross-AZ dependency) | 365 days |

### Subnet layout (example: 10.10.0.0/16)

| Range | Use | Size |
|---|---|---|
| 10.10.0.0 – 10.10.191.255 | private subnets, one per AZ letter a–f | /19 (8,190 IPs) |
| 10.10.192.0 – 10.10.215.255 | public subnets, one per AZ letter a–f | /22 (1,022 IPs) |
| 10.10.216.0 – 10.10.255.255 | free, reserved for future tiers (e.g. database) | — |

Each subnet's CIDR comes from its **AZ letter**, not from its position in `azs`.
Reordering or removing an AZ never changes (and never recreates) the subnets of the others.

## Repository layout

```
modules/vpc/          reusable module (the "template")
modules/vpc/tests/    terraform test suite (mocked AWS provider)
e2e/aws/              end-to-end test in a real account (run manually, then destroy)
envs/dev/             root config: calls the module with dev values
envs/stage/           root config: calls the module with stage values
envs/prod/            root config: calls the module with prod values
docs/                 architecture diagram (SVG) and build guide
.github/workflows/    CI: fmt, validate, test, tflint, checkov
```

## Usage

```hcl
provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["123456789012"] # refuse to run against any other account
}

module "vpc" {
  source = "github.com/johnvega-cloud/terraform-aws-vpc-multiaz//modules/vpc?ref=v1.0.0"

  project     = "jv"
  environment = "prod"

  vpc_cidr           = "10.30.0.0/16"
  azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
  single_nat_gateway = false

  flow_logs_retention_days = 365

  tags = {
    Owner      = "platform-team"
    CostCenter = "1234"
  }
}

# Consumers use the outputs, e.g. an EKS cluster:
#   subnet_ids = module.vpc.private_subnet_ids
```

The region is **not** a module input: the module inherits it from the caller's
provider, so the same code works in any region.

### Deploying an environment

```bash
cd envs/dev
cp terraform.tfvars.example terraform.tfvars   # set aws_account_id (git-ignored)
terraform init
terraform plan -out=tfplan                      # review: dev = 28 resources
terraform apply tfplan
terraform destroy                               # lab: tear down when done (NAT bills hourly)
```

Prerequisites: Terraform >= 1.7, AWS credentials for the target account
(`aws sts get-caller-identity` must show the account in `aws_account_id`) with
permissions for EC2/VPC, CloudWatch Logs and IAM (role for flow logs).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project` | string | — (required) | 2–6 lowercase chars, first part of every name. |
| `environment` | string | — (required) | `dev`, `stage` or `prod`. |
| `vpc_cidr` | string | — (required) | IPv4 CIDR, /16 to /20. Must not overlap other environments. |
| `azs` | list(string) | — (required) | 2–4 AZ names, no duplicates. The first one hosts the shared NAT. |
| `single_nat_gateway` | bool | `false` | `true` = one shared NAT (cheaper); `false` = one NAT per AZ (resilient). |
| `interface_endpoints` | set(string) | `["ecr.api", "ecr.dkr"]` | Services that get an Interface endpoint. S3 Gateway is always created. |
| `enable_flow_logs` | bool | `true` | Send VPC Flow Logs to CloudWatch Logs. |
| `flow_logs_retention_days` | number | `30` | Retention, any value CloudWatch accepts. |
| `flow_logs_kms_key_arn` | string | `null` | Optional customer-managed KMS key for the log group. |
| `iam_role_name_prefix` | string | `""` | Prefix for the Flow Logs IAM role name, for accounts whose IAM policies only allow roles matching a pattern. |
| `tags` | map(string) | `{}` | Extra tags. Cannot override `Project`, `Environment`, `ManagedBy`, `Module`. |

All inputs are validated at plan time (bad CIDR, one AZ, duplicate AZs, unknown
environment... fail before anything reaches AWS).

## Outputs

| Name | Description |
|---|---|
| `name` | Base name `<project>-<env>-<region>`. |
| `vpc_id`, `vpc_cidr`, `azs` | The VPC and the AZs it spans. |
| `public_subnet_ids`, `private_subnet_ids` | Subnet ID lists (ALB, EKS, RDS subnet groups). |
| `public_subnets_by_az`, `private_subnets_by_az` | Map AZ → `{id, cidr}`. |
| `public_route_table_id`, `private_route_table_ids` | For adding routes (Transit Gateway, peering). |
| `nat_public_ips` | Egress IPs, for third-party allow-lists. |
| `s3_endpoint_id`, `interface_endpoint_ids`, `endpoints_security_group_id` | Endpoint resources. |
| `flow_logs_log_group_name` | Flow Logs destination (`null` if disabled). |

## Naming convention

Every resource is named `<project>-<env>-<region>-<resource>[-<az>]`:

| Resource | Example |
|---|---|
| VPC | `jv-dev-use1-vpc` |
| Private subnet in AZ a | `jv-dev-use1-private-a` |
| NAT gateway in AZ a | `jv-dev-use1-nat-a` |
| Interface endpoint (ECR API) | `jv-dev-use1-vpce-ecr-api` |

- `project` is set by the caller (no default in the module).
- The region short code is derived from the provider region (`us-east-1` → `use1`, `eu-west-2` → `euw2`).
- Names are for humans; **tags** are for automation, cost reports and audits. Every resource gets
  `Project`, `Environment`, `ManagedBy = terraform` plus any extra `tags` passed by the caller
  (caller tags cannot override the mandatory ones).

## Security notes

- **No public exposure by default**: public subnets do not auto-assign public IPs;
  workloads go in private subnets with egress only through NAT.
- **Default security group locked down** (no rules) — CIS AWS Foundations "default SG restricts all traffic".
- **Endpoint security group** allows only TCP 443 from the VPC CIDR.
- **Flow Logs** capture `ALL` traffic (rejected connections are the interesting part).
  The IAM role trusts only `vpc-flow-logs.amazonaws.com` for **this** account
  (`aws:SourceAccount` / `aws:SourceArn`, prevents confused-deputy) and can write only
  to its own log group.
- **Wrong-account guard**: each environment sets `allowed_account_ids`; Terraform
  aborts if the credentials belong to another account.
- **Secrets and state stay out of git**: `*.tfstate`, `*.tfvars` and plans are ignored;
  only `terraform.tfvars.example` is committed.
- **checkov** runs in CI. Accepted findings are suppressed inline with a written
  reason (`checkov:skip=...`): two false positives (SG and EIP *are* attached) and two
  caller-controlled settings (log retention, CMK encryption).

## Idempotency and safe changes

- Running `apply` twice makes no changes the second time (`No changes`).
- Subnets, NATs and route tables use `for_each` keyed by **AZ name**, never `count`,
  so adding or removing an AZ only touches that AZ.
- Subnet CIDRs come from the AZ letter → stable across list edits (covered by a test).
- Every AZ keeps its own private route table even in single-NAT mode, so switching
  `single_nat_gateway` from `true` to `false` only re-points routes; no subnet is recreated.
- Routes are separate `aws_route` resources, so other stacks can add routes
  (e.g. Transit Gateway) without Terraform removing them.
- Provider builds are pinned per environment by the committed `.terraform.lock.hcl`
  (CI initializes with `-lockfile=readonly`).

## Cost (approximate, us-east-1 list prices — check the AWS pricing pages)

| Item | Unit price | dev / stage | prod |
|---|---|---|---|
| NAT gateway | ~$0.045/h + ~$0.045/GB processed | 1 → ~$33/month | 3 → ~$99/month |
| Interface endpoint | ~$0.01/h per AZ per endpoint | 2 × 2 AZ → ~$29/month | 2 × 3 AZ → ~$44/month |
| Public IPv4 (NAT EIP) | ~$0.005/h | ~$4/month | ~$11/month |
| S3 Gateway endpoint | free | — | — |
| Flow Logs | per GB ingested + stored | usage-based | usage-based |

The NAT gateway dominates. That is why dev/stage share one NAT and why S3/ECR
traffic goes through endpoints instead of the NAT. **Destroy lab environments when not in use.**

## Testing and CI

```bash
cd modules/vpc
terraform init -backend=false
terraform test        # 17 runs, mocked AWS provider: no credentials, no cost
```

The suite checks naming and mandatory tags, the CIDR layout and its stability
when the AZ list changes, single vs per-AZ NAT routing, S3/ECR endpoint wiring,
optional flow logs, and that invalid inputs are rejected.

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every
push and pull request, without AWS credentials:

| Job | What it checks |
|---|---|
| `terraform fmt` | Formatting |
| `validate` | Module and each environment, with the committed lock files |
| `terraform test` | The unit test suite above |
| `tflint` | Recommended rules + AWS ruleset + documented variables/outputs |
| `checkov` | Security misconfigurations |

### End-to-end test in real AWS

[`e2e/aws/`](e2e/aws/README.md) deploys the module plus a probe instance in a private
subnet (SSM only, no SSH) and checks real traffic. It is run by hand, not in CI,
because it costs money while it is up. Last run: 2026-10-20, us-east-1.

| Check | Result |
|---|---|
| `apply` | 40 resources created, including the Flow Logs IAM role |
| Egress IP from a private subnet | the NAT gateway's Elastic IP |
| `api.ecr` / `dkr.ecr` DNS from the VPC | private `10.10.x.x` addresses; `ecr get-login-password` ok |
| S3 read | succeeds only through the gateway endpoint (bucket policy denies any other path) |
| Flow Logs | `ACTIVE`, delivery `SUCCESS`, `ACCEPT` records in CloudWatch |
| Second `plan -detailed-exitcode` | `0`: no changes (idempotent) |
| `destroy` | 40 destroyed, nothing left behind |

## Requirements

| Tool | Version |
|---|---|
| Terraform | >= 1.7 (CI uses 1.14.7) |
| AWS provider | >= 6.0, < 7.0 |

## Author

John Vega
