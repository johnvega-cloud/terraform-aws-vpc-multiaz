# End-to-end test (real AWS)

Deploys the module in a real account, proves that traffic actually flows the
way the design says, and is destroyed afterwards. Unit tests (`terraform test`
with a mocked provider) prove the plan is right; this proves AWS agrees.

**Cost:** NAT gateway + 2 Interface endpoints + 1 t3.micro, roughly USD 0.15/hour.
Destroy it as soon as the checks pass.

## Run

```bash
cd e2e/aws
terraform init
terraform plan -var aws_account_id=<ACCOUNT_ID> -out=tfplan
# Accounts whose IAM policies only allow roles matching a pattern:
#   add -var iam_role_name_prefix=<prefix>
terraform apply tfplan
```

## Checks

Wait ~2 minutes after apply for the probe instance to register with SSM, then:

```bash
ID=$(terraform output -raw probe_instance_id)
BUCKET=$(terraform output -raw bucket)
NAT_IP=$(terraform output -json nat_public_ips | jq -r '.[0]')

CMD=$(aws ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
  --parameters "commands=[
    \"echo EGRESS_IP=\$(curl -s https://checkip.amazonaws.com)\",
    \"echo ECR_API=\$(getent hosts api.ecr.us-east-1.amazonaws.com | cut -d' ' -f1)\",
    \"aws ecr get-login-password --region us-east-1 >/dev/null && echo ECR_LOGIN=ok\",
    \"aws s3 cp s3://$BUCKET/marker.txt - && echo\"
  ]" --query Command.CommandId --output text)
sleep 10
aws ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" \
  --query StandardOutputContent --output text
```

| Check | Expected | Proves |
|---|---|---|
| `EGRESS_IP` | equals `$NAT_IP` | private subnet reaches the internet through the NAT gateway |
| `ECR_API` | a `10.10.x.x` address | ECR Interface endpoint + private DNS work |
| `ECR_LOGIN` | `ok` | ECR API answers through the endpoint |
| `marker.txt` | `reached-through-vpce` | S3 traffic uses the gateway endpoint (the bucket policy denies the probe's reads on any other path) |
| `aws logs describe-log-streams --log-group-name $(terraform output -raw flow_logs_log_group_name)` | at least one stream (~10 min after apply) | Flow Logs deliver to CloudWatch with the module's IAM role |
| `terraform plan -detailed-exitcode` | exit code `0` | the module is idempotent |

## Destroy

```bash
# Pass the same -var values used for apply (including iam_role_name_prefix)
terraform plan -destroy -var aws_account_id=<ACCOUNT_ID> -out=tfdestroy
terraform apply tfdestroy
```
