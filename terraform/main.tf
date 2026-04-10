terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state in S3 (recommended for teams):
  # backend "s3" {
  #   bucket = "your-tf-state-bucket"
  #   key    = "sip-gateway/terraform.tfstate"
  #   region = "ap-south-1"
  # }
}

provider "aws" {
  region = var.region
}

# ---- Auto-detect default VPC/subnet if not provided ----

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  vpc_id    = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default[0].ids[0]
}

# ---- AMI ----

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---- Elastic IP (static — this is what gets whitelisted) ----

resource "aws_eip" "sip_gateway" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.instance_name}-eip"
  })
}

resource "aws_eip_association" "sip_gateway" {
  instance_id   = aws_instance.sip_gateway.id
  allocation_id = aws_eip.sip_gateway.id
}

# ---- Security group ----

resource "aws_security_group" "sip_signaling" {
  name        = "${var.instance_name}-sip-signaling"
  description = "SIP signaling and RTP media for sip-gateway"
  vpc_id      = local.vpc_id

  ingress {
    description = "SIP UDP"
    from_port   = 5060
    to_port     = 5060
    protocol    = "udp"
    cidr_blocks = var.allowed_sip_source_ranges
  }

  ingress {
    description = "SIP TCP"
    from_port   = 5060
    to_port     = 5060
    protocol    = "tcp"
    cidr_blocks = var.allowed_sip_source_ranges
  }

  ingress {
    description = "SIP TLS"
    from_port   = 5061
    to_port     = 5061
    protocol    = "tcp"
    cidr_blocks = var.allowed_sip_source_ranges
  }

  ingress {
    description = "RTP media"
    from_port   = 10000
    to_port     = 20000
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_source_ranges
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.instance_name}-sg"
  })
}

# ---- EC2 instance ----

resource "aws_instance" "sip_gateway" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.sip_signaling.id]
  associate_public_ip_address = true
  user_data                   = file("${path.module}/../scripts/startup.sh")

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(var.tags, {
    Name = var.instance_name
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
