# The Ansible test host — launch, use, terminate

A hand-launched throwaway EC2 instance the box playbook (`ansible/site.yml`) is
proven against: a fresh Debian 12 is the blank host on every acceptance run
(DESIGN, "The playbook's rulings"). Never in a stack's state, never left running: the
cost is ~$0.02/h, the AWS cost alert is the backstop, the TODO in the platform
stream carries the ids while one exists.

Region `eu-central-1`, profile `leave-impact` (`$env:AWS_PROFILE="leave-impact"`
per PowerShell window). The security group `ansible-throwaway` (22 from the
workstation IP, 443 open to the internet so the origin-firewall check is real)
and the key pair `ansible-throwaway` (private key in WSL at
`~/.ssh/ansible-throwaway`, never under a repository) persist across launches;
delete them with the last instance.

## Launch

```powershell
$env:AWS_PROFILE = "leave-impact"
# Debian 12 (bookworm) amd64, the official image in eu-central-1 as of 2026-08-28.
# The live box runs Debian 13 (trixie): the next drill should launch a trixie image,
# so the proof host and the described host share a major (found 2026-08-30, when the
# box's image turned out to ship no gnupg while this one did).
aws ec2 run-instances --region eu-central-1 `
  --image-id ami-0e63e247af0c8ff56 --instance-type t3.micro `
  --key-name ansible-throwaway --security-group-ids <sg-id> `
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ansible-throwaway}]' `
  --query 'Instances[0].InstanceId' --output text
aws ec2 describe-instances --region eu-central-1 --filters Name=tag:Name,Values=ansible-throwaway Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' --output text
```

After every launch, list by **security group**, not by tag: a launch whose tag
spec was mangled by PowerShell quoting still launches, untagged (one such stray
ran three hours on 2026-08-28 and blocked the group's delete).

```powershell
aws ec2 describe-instances --region eu-central-1 --filters Name=instance.group-name,Values=ansible-throwaway Name=instance-state-name,Values=running `
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' --output text
```

Put the public IP into `ansible/inventory/local.yml` (gitignored; shape in
`example.yml`). If the workstation's IP changed, update the group's port-22
rule first (`aws ec2 authorize-security-group-ingress` / `revoke-...`).

## Use (from WSL, the control node)

The `proxy` role copies the origin pair from `~/.platform/certs/` on the control
node (`platform_certs_dir`). A test host gets a self-signed pair under the same
two names, so the real Origin CA key never leaves the workstation for a test;
generate it once, outside any repository:

```sh
mkdir -p ~/.platform/certs && chmod 0700 ~/.platform/certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj '/CN=*.ardabasarici.dev' -addext 'subjectAltName=DNS:*.ardabasarici.dev,DNS:ardabasarici.dev' \
  -keyout ~/.platform/certs/ardabasarici.dev.key -out ~/.platform/certs/ardabasarici.dev.pem
chmod 0600 ~/.platform/certs/ardabasarici.dev.key
```

(`curl -k` in the checks below is what tolerates it; on the box the same path
holds the Cloudflare-issued pair, copied there by hand per `box/README.md`.)

A run against the **live box** needs the live pair at the same path, or the proxy
role reports a certificate replacement. Copy it in for the run only: on the box,
`sudo install` both files into a staging directory owned by the login user; `scp`
them into `~/.platform/certs`; remove the staging directory; after the run, remove
the copy and put the test pair back. The control node is not a store for that pair
(SECRETS: re-issuable, not recoverable). The live box is `box` in WSL's own
`~/.ssh/config` with the dedicated key `~/.ssh/platform-box` (passphrase-protected;
`ssh-add` it once per shell), and sudo comes through `--ask-become-pass`. Check
mode first: `ansible-playbook -i inventory/local.yml site.yml --check --diff
--ask-become-pass`, every `changed` explained before any real run.

```sh
cd /mnt/c/Users/ardab/Desktop/projects/platform/ansible
export ANSIBLE_CONFIG=/mnt/c/Users/ardab/Desktop/projects/platform/ansible/ansible.cfg   # absolute: /mnt/c is world-writable, the cwd cfg is ignored
ansible -i inventory/local.yml all -m ping                     # pong first
ansible-playbook -i inventory/local.yml site.yml               # the build
ansible-playbook -i inventory/local.yml site.yml               # must say changed=0
ansible -i inventory/local.yml all -b -m script -a verify.sh   # ALL PASS
curl -sk --connect-timeout 6 https://<public-ip>/ ; echo $?    # 28: the bare IP times out
```

The roles clone `/srv/platform` from GitHub `main`: a change to `box/` files is
exercised on the host only after it is pushed. From PowerShell, wrap the whole
thing in `wsl -- bash -lc '...'` with inner double quotes escaped as `\"` (PS 5.1
drops unescaped inner quotes from a native command's argument).

## Terminate

```powershell
aws ec2 terminate-instances --region eu-central-1 --instance-ids <instance-id>
# With the last instance, the group and the key pair too:
aws ec2 delete-security-group --region eu-central-1 --group-id <sg-id>
aws ec2 delete-key-pair --region eu-central-1 --key-name ansible-throwaway
```
