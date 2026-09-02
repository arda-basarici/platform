# The application host: one arm instance behind Cloudflare, administered over
# SSM. The ruling ("one EC2 instance, one Compose stack") and its reasons are
# the leave-impact-agent repository's DESIGN; this file is the mechanics.

# --- Ingress: the security group is the AWS twin of the box's firewall.sh -----
# 443 from Cloudflare's pinned ranges and nothing else — no 22, no 80. A scanner
# that finds the Elastic IP gets silence; the only working path is through
# Cloudflare's edge, where TLS and bot cover live.
resource "aws_security_group" "app" {
  name        = "leave-agent-app"
  description = "443 from Cloudflare edge ranges only; no SSH (SSM instead)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "leave-agent-app" }
}

resource "aws_vpc_security_group_ingress_rule" "https_from_cloudflare" {
  for_each = toset(var.cloudflare_ipv4_ranges)

  security_group_id = aws_security_group.app.id
  description       = "Cloudflare edge"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Outbound stays open: image pulls, SSM's agent channel, Parameter Store,
# Bedrock, and the world's SaaS APIs (Jira, Google, Frappe on the box) are all
# outbound. Tightening egress is a later hardening step, not a first-milestone
# criterion.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Identity: what code on the instance may do ------------------------------
# Least privilege at the role, not the process: SSM's own channel, plus reads
# of this project's parameters by path prefix. `ssm:GetParameter` on `*` would
# silently grant every future secret in the account.
data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "leave-agent-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance_secrets" {
  statement {
    sid       = "ReadProjectParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:eu-central-1:${data.aws_caller_identity.current.account_id}:parameter/leave-agent/*"]
  }
}

resource "aws_iam_role_policy" "instance_secrets" {
  name   = "read-project-parameters"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_secrets.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "leave-agent-instance"
  role = aws_iam_role.instance.name
}

data "aws_caller_identity" "current" {}

# --- The host --------------------------------------------------------------
# Amazon Linux 2023 arm64, resolved through AWS's public SSM parameter so the
# AMI id is never hand-copied. `ignore_changes` on the AMI keeps a routine plan
# from proposing a replacement every time Amazon publishes a new image; an
# upgrade is a deliberate `-replace`.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # No key pair: SSH is not a path into this host.
  key_name = null

  # IMDSv2 only — the credential endpoint answers signed session requests, not
  # a bare GET a server-side request forgery could reach.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers reach IMDS through one extra hop
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    app_hostname           = var.app_hostname
    cloudflare_ipv4_ranges = var.cloudflare_ipv4_ranges
  })
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "leave-agent-app" }
}

# Stable public address: the Cloudflare A record points here and survives an
# instance replacement (re-attach, no DNS change).
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id

  tags = { Name = "leave-agent-app" }
}

# --- Data volume -------------------------------------------------------------
# State (PostgreSQL, proxy certs, compose files) lives on its own volume,
# mounted at /srv by first boot, so the root volume and the instance are
# replaceable without touching data. Deleting this volume is a deliberate act.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  type              = "gp3"
  size              = 20
  encrypted         = true

  tags = { Name = "leave-agent-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}
