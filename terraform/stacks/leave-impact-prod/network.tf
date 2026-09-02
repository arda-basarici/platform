# One VPC, one public subnet, IPv4 only. The instance is the sole tenant and
# Cloudflare is its only caller, so there is nothing for private subnets, NAT, or
# IPv6 to serve yet; each would be added on a concrete need (the ephemeral-compute
# experiment the leave-impact-agent repository's DESIGN preregisters for a later
# milestone is the likely one), not by default.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "leave-agent" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "leave-agent" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "eu-central-1a"

  # The instance carries an Elastic IP instead; no auto-assigned address that
  # would change on every replacement.
  map_public_ip_on_launch = false

  tags = { Name = "leave-agent-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "leave-agent-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
