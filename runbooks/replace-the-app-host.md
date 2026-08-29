# Runbook — replace the app host's instance

Any change to `terraform/stacks/leave-impact-prod/user_data.sh.tftpl` replaces the
EC2 instance (`user_data_replace_on_change`), and so does an instance-type or
AMI change that is not under `ignore_changes`. The data volume is a separate
resource and survives; only its attachment follows the new instance. The Elastic
IP moves with it, so no DNS changes. First exercised 2026-08-29 for the Caddy
client-IP change; kept current each time it runs.

What is down: everything on the host, from the destroy until first boot finishes
(observed: 84 s of first boot, about three minutes end to end). Today that is a
hello page; once the application is deployed it is the application, and the
next approved deploy from the agent repository puts it back (a replaced instance
serves the hello page until then). Choose the moment accordingly.

## Before the apply

```powershell
$env:AWS_PROFILE = "leave-impact"
# 1. The plan says exactly this and nothing more: aws_instance.app "must be
#    replaced" (user_data forces replacement), aws_volume_attachment.data
#    replaced, aws_eip.app updated in-place. The aws_ebs_volume is NOT in it.
terraform -chdir=terraform/stacks/leave-impact-prod plan
# 2. The three parameters the boot script polls are present (versions, no values):
aws ssm describe-parameters --region eu-central-1 --parameter-filters "Key=Path,Values=/leave-agent/" --query 'Parameters[].[Name,Version]' --output text
# 3. secrets.tf: value_wo_version is untouched (1) — a changed value would make
#    this apply overwrite the real values with the placeholder (CLAUDE.md lesson).
```

If the Caddyfile inside the template changed, validate the rendered result with
a real Caddy before the apply (render the heredoc with the ranges and hostname
substituted, a throwaway self-signed pair at `/certs/`, `caddy validate` in the
`caddy:2-alpine` image; a run that reports the image's default config as valid is
a mount that failed, not a pass — the output names the SANs of the pair it read).

## The apply

```powershell
terraform -chdir=terraform/stacks/leave-impact-prod apply
# Expected: Apply complete! Resources: 2 added, 1 changed, 2 destroyed.
```

## After the apply, in order — each answers a different question

```powershell
$R = "eu-central-1"
# 1. The new instance, by tag (the id changed; nothing addresses it by id).
aws ec2 describe-instances --region $R --filters Name=tag:Name,Values=leave-agent-app Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceId,LaunchTime]' --output text
# 2. Gate, not evidence: SSM online (the agent is up before the boot script ends).
aws ssm describe-instance-information --region $R --filters Key=InstanceIds,Values=<id> --query 'InstanceInformationList[].PingStatus' --output text
# 3. Script success: the boot log ends with the done line.
# 4. The persistent volume is what /srv is mounted from: source nvme, ext4,
#    LABEL leave-agent-data, and the directories from before (app pgdata proxy).
#    A fresh format boots just as cleanly and logs the same success — this is
#    the only check that tells the two apart.
aws ssm send-command --region $R --instance-ids <id> --document-name AWS-RunShellScript --parameters 'commands=["tail -n 2 /var/log/leave-agent-boot.log","findmnt -no SOURCE,FSTYPE,LABEL /srv","ls /srv","docker ps --format \"{{.Names}} {{.Status}}\""]' --query Command.CommandId --output text
aws ssm get-command-invocation --region $R --command-id <cid> --instance-id <id> --query StandardOutputContent --output text
# Expected: "=== first boot done <time> ===" · "/dev/nvme1n1 ext4 leave-agent-data"
#           · app lost+found pgdata proxy · proxy-caddy-1 Up, proxy-hello-1 Up
```

```sh
# 5+6. The public path, and the client-IP contract in the same response:
#      200; X-Forwarded-For is ONE entry, equal to Cf-Connecting-Ip, equal to
#      the workstation's public IP (never a Cloudflare range).
curl -s -w '\nHTTP %{http_code}\n' https://leave-agent.ardabasarici.dev/ | grep -Ei '^(HTTP|Name:|X-Forwarded-For:|Cf-Connecting-Ip:)'
```

```powershell
# 7. The stack is quiet again.
terraform -chdir=terraform/stacks/leave-impact-prod plan     # No changes.
```

## Rollback

The template is one commit: revert it, apply again, run the same seven checks.
The data volume is untouched either way. If the boot script itself failed (no
done line), read the whole `/var/log/leave-agent-boot.log` over SSM first; the
usual causes are a parameter still holding its placeholder (the poll times out
after 30 minutes with "origin pair never arrived") or the data device not
appearing at `/dev/sdf`.
