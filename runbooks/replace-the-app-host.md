# Runbook — replace the app host's instance

Any change to `terraform/stacks/leave-impact-prod/user_data.sh.tftpl` replaces the
EC2 instance (`user_data_replace_on_change`), and so does an instance-type
change (the AMI is under `ignore_changes`; an image upgrade is a deliberate
`-replace`). The data volume is a separate
resource and survives; only its attachment follows the new instance. The Elastic
IP moves with it, so no DNS changes. First exercised 2026-08-29 for the Caddy
client-IP change; kept current each time it runs.

What is down: everything on the host, from the destroy until first boot finishes
(observed: 84 s of first boot, about three minutes end to end), and then the
application until the next approved deploy from the agent repository lands it
again: a replaced instance answers 502 from Caddy until then, since the
application's service name does not resolve on `web` before the deploy (the data
volume, with PostgreSQL's data, the deploy marker and the platform checkout,
survives). Choose the moment accordingly, and have the agent side dispatch its
deploy right after. The agent side has no manual deploy trigger: the deploy is
CI's job on a push to `main`, and re-landing the same commit on a fresh host is a
rerun of that job from its run (`gh run rerun <run> --job <job>`), approved in
Actions (exercised 2026-10-24). The `/ready` keyword monitor sees the gap: expect a
DOWN mail for the window and an UP once the deploy lands (the pair on 2026-10-24:
20:46:26 to 20:55:19).

## Before the apply

```powershell
$env:AWS_PROFILE = "leave-impact"
# 0. A backup object for today first (since 2026-10-23). The data volume survives
#    a replacement by design; the object that exists before the destroy is the
#    recovery if the attachment does not. The key is one per UTC day and the put is
#    create-only, so after the 03:30 UTC nightly the check is the listing, and a
#    hand run of the unit is refused with PreconditionFailed (exit 254; observed
#    2026-10-24, the design working). Before the nightly, run the unit by hand over
#    SSM (the send-command shape is step 4 below; the command list is
#    ["systemctl start leave-impact-backup.service","journalctl -u leave-impact-backup.service -n 3 --no-pager"])
#    and read its "backup ok" line.
aws s3api list-objects-v2 --region eu-central-1 --bucket leave-impact-backup-445743457479 --prefix daily/ --query 'Contents[].[Key,Size,LastModified]' --output text
#    Expected: today's daily/leaveimpact-<date>.dump listed.
# 1. The plan says exactly this and nothing more: aws_instance.app "must be
#    replaced" (user_data forces replacement), aws_volume_attachment.data
#    replaced, aws_eip.app and the two status-check alarms (they key on the
#    instance id) updated in-place. The aws_ebs_volume is NOT in it.
terraform -chdir=terraform/stacks/leave-impact-prod plan
# 2. The three parameters the boot script polls are present (versions, no values):
aws ssm describe-parameters --region eu-central-1 --parameter-filters "Key=Path,Values=/leave-agent/" --query 'Parameters[].[Name,Version]' --output text
# 3. secrets.tf: value_wo_version is untouched (1) — a changed value would make
#    this apply overwrite the real, out-of-band values with the placeholder; if it
#    must change: save the values, apply, re-put, read back (ARCHITECTURE, the
#    state map).
```

If the Caddyfile inside the template changed, validate the rendered result with
a real Caddy before the apply (render the heredoc with the ranges and hostname
substituted, a throwaway self-signed pair at `/certs/`, `caddy validate` in the
`caddy:2-alpine` image; a run that reports the image's default config as valid is
a mount that failed, not a pass — the output names the SANs of the pair it read).

## The apply

```powershell
terraform -chdir=terraform/stacks/leave-impact-prod apply
# Expected: Apply complete! Resources: 2 added, 3 changed, 2 destroyed.
```

## After the apply, in order — each answers a different question

```powershell
$R = "eu-central-1"
# 1. The new instance, by tag (the id changed; nothing addresses it by id); keep it in $I.
aws ec2 describe-instances --region $R --filters Name=tag:Name,Values=leave-agent-app Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceId,LaunchTime]' --output text
# 2. Gate, not evidence: SSM online (the agent is up before the boot script ends).
aws ssm describe-instance-information --region $R --filters Key=InstanceIds,Values=<id> --query 'InstanceInformationList[].PingStatus' --output text
# 3. Script success: the boot log ends with the done line.
# 4. The persistent volume is what /srv is mounted from: source nvme, ext4,
#    LABEL leave-agent-data, and the directories from before (app pgdata proxy).
#    A fresh format boots just as cleanly and logs the same success — this is
#    the only check that tells the two apart.
#    The command list goes through a file: PowerShell 5.1 splits the inline
#    `commands=[...]` form at its inner quotes before the CLI sees it. The CLI
#    prints in the console codepage and aborts on a glyph it cannot map, so
#    `chcp 65001` first and keep the host commands' output ASCII (no `--format`
#    with quotes, `lsblk -i`); a "charmap codec" error names a position in the
#    output and is never a credentials failure.
'{"commands":["tail -n 2 /var/log/leave-agent-boot.log","journalctl --list-boots --no-pager","findmnt -no SOURCE,FSTYPE,LABEL /srv","ls /srv","docker ps --format {{.Names}}:{{.Status}}","docker network inspect web --format {{range.IPAM.Config}}{{.Subnet}}{{end}}","systemctl list-timers --no-pager leave-impact-*","cat /etc/platform/leave-impact/backup.env","find /etc/systemd/system -name leave-impact-* -size 0"]}' | Out-File -Encoding ascii "$env:TEMP/ssm-check.json"
#    Capture the command id into a variable: a placeholder left in the next line
#    is a parse error in PowerShell (`<` is reserved).
$C = aws ssm send-command --region $R --instance-ids $I --document-name AWS-RunShellScript --parameters "file://$env:TEMP/ssm-check.json" --query Command.CommandId --output text
Start-Sleep 8
aws ssm get-command-invocation --region $R --command-id $C --instance-id $I --query StandardOutputContent --output text
# Expected: "=== first boot done <time> ===" · exactly ONE boot listed (a second boot
#           within minutes of launch means something reset the host mid-script and every
#           unflushed write of first boot is a zero-length file: the 2026-10-23 replacement,
#           reset by the status-check alarm's recover action) · "/dev/nvme1n1 ext4 leave-agent-data"
#           · app backups lost+found pgdata platform proxy · proxy-caddy-1 Up and nothing else (the
#           application's containers arrive with the deploy) · the web network's subnet 172.18.0.0/16
#           (pinned since 2026-10-24: the application trusts forwarded headers from that range)
#           · the two leave-impact timers listed with a next run · BACKUP_BUCKET=leave-impact-backup-<account>
#           · the find line empty (a zero-length unit file is the mid-boot reset's signature)
#    The platform checkout is what the host pulled from GitHub main at boot: a change
#    under projects/leave-impact/ that is not pushed is not on the host.
```

```sh
# 5. The public path before the deploy: 502 from Caddy (text/plain, 16 bytes), not
#    521 (the origin unreachable: the security group or Caddy itself) and not the
#    application's own answer.
curl -s -o /dev/null -w 'HTTP %{http_code} size %{size_download}\n' https://leave-agent.ardabasarici.dev/ready
# 6. After the agent side's deploy: the health route through the hostname, a JSON
#    body with "ready":true and the deployed commit (the keyword monitor reads the
#    same route), and the replay listing with a body.
curl -s -w '\nHTTP %{http_code}\n' https://leave-agent.ardabasarici.dev/ready
curl -s -o /dev/null -w 'HTTP %{http_code} %{content_type} size %{size_download}\n' https://leave-agent.ardabasarici.dev/replays
#    The client-IP contract (X-Forwarded-For one entry, the verified visitor) is no
#    longer readable from a response since the echo page went on 2026-10-24: it is
#    stated in the rendered Caddyfile (header_up, read the adapted JSON when it
#    changes) and observed in the application's own request handling, whose
#    per-address limit (its step 13) is the consumer that fails loudly if it breaks.
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
