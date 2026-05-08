terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Data sources ───────────────────────────────────────────────────────────

# Ubuntu 24.04 (Apache + Tomcat)
data "aws_ami" "hc-base-ubuntu-2404" {
  for_each = toset(["amd64", "arm64"])
  filter {
    name   = "name"
    values = [format("hc-base-ubuntu-2404-%s-*", each.value)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

# Windows Server 2025 (IIS)
data "aws_ami" "windows_2025" {
  filter {
    name   = "name"
    values = ["hc-base-windows-server-2025*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── IAM Role for SSM Session Manager ──────────────────────────────────────
# Allows connecting to instances without opening SSH/RDP ports

resource "aws_iam_role" "ssm_role" {
  name = "vault-pki-demo-ssm-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "vault-pki-demo-ssm", Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "vault-pki-demo-ssm-${var.environment}"
  role = aws_iam_role.ssm_role.name
}

# ── Security Groups ────────────────────────────────────────────────────────

resource "aws_security_group" "linux_sg" {
  name        = "vault-demo-linux-${var.environment}"
  description = "Apache and Tomcat demo instances"
  vpc_id      = data.aws_vpc.default.id

  # HTTPS inbound (demo traffic)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  # HTTP — redirect to HTTPS only; keep for demo visibility
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  # Tomcat default port
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Tomcat HTTPS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vault-demo-linux", Environment = var.environment }
}

resource "aws_security_group" "windows_sg" {
  name        = "vault-demo-windows-${var.environment}"
  description = "IIS demo instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vault-demo-windows", Environment = var.environment }
}

# ── Apache Instance ────────────────────────────────────────────────────────

resource "aws_instance" "apache" {
  ami                    = data.aws_ami.hc-base-ubuntu-2404["amd64"].id
  instance_type          = var.instance_type_linux
  key_name               = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.linux_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/linux_userdata.sh.tpl", {
    vault_addr      = var.vault_addr
    vault_namespace = var.vault_namespace
    role_id         = vault_approle_auth_backend_role.roles["apache"].role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.secret_ids["apache"].secret_id
    platform        = "apache"
    vault_version   = var.vault_version
    pki_role_path   = "${vault_mount.pki_int.path}/issue/apache-role-${var.customer_name}"
    common_name     = var.cert_domain_linux
    cert_ttl        = var.cert_ttl
    vault_agent_config = templatefile("${path.module}/templates/vault-agent/agent.hcl.tpl", {
      vault_addr      = var.vault_addr
      vault_namespace = var.vault_namespace
      approle_mount   = vault_auth_backend.approle.path
      cert_base_dir   = "/etc/vault-agent"
      exec_command    = jsonencode(["systemctl", "reload", "apache2"])
      exec_timeout    = "30s"
    })
  })

  tags = {
    Name        = "vault-demo-apache"
    Environment = var.environment
    Owner       = var.owner
    Platform    = "apache"
    ManagedBy   = "terraform"
  }
}

# ── Tomcat Instance ────────────────────────────────────────────────────────

resource "aws_instance" "tomcat" {
  ami                    = data.aws_ami.hc-base-ubuntu-2404["amd64"].id
  instance_type          = var.instance_type_linux
  key_name               = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.linux_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/linux_userdata.sh.tpl", {
    vault_addr      = var.vault_addr
    vault_namespace = var.vault_namespace
    role_id         = vault_approle_auth_backend_role.roles["tomcat"].role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.secret_ids["tomcat"].secret_id
    platform        = "tomcat"
    vault_version   = var.vault_version
    pki_role_path   = "${vault_mount.pki_int.path}/issue/tomcat-role-${var.customer_name}"
    common_name     = var.cert_domain_tomcat
    cert_ttl        = var.cert_ttl
    vault_agent_config = templatefile("${path.module}/templates/vault-agent/agent.hcl.tpl", {
      vault_addr      = var.vault_addr
      vault_namespace = var.vault_namespace
      approle_mount   = vault_auth_backend.approle.path
      cert_base_dir   = "/etc/vault-agent"
      exec_command    = jsonencode(["/etc/vault-agent/hooks/tomcat-reload.sh"])
      exec_timeout    = "60s"
    })
  })

  tags = {
    Name        = "vault-demo-tomcat"
    Environment = var.environment
    Owner       = var.owner
    Platform    = "tomcat"
    ManagedBy   = "terraform"
  }
}

# ── IIS (Windows) Instance ─────────────────────────────────────────────────

resource "aws_instance" "iis" {
  ami                    = data.aws_ami.windows_2025.id
  instance_type          = var.instance_type_windows
  key_name               = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.windows_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/windows_userdata.ps1.tpl", {
    vault_addr      = var.vault_addr
    vault_namespace = var.vault_namespace
    role_id         = vault_approle_auth_backend_role.roles["iis"].role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.secret_ids["iis"].secret_id
    vault_version   = var.vault_version
    pki_role_path   = "${vault_mount.pki_int.path}/issue/iis-role-${var.customer_name}"
    common_name     = var.cert_domain_windows
    cert_ttl        = var.cert_ttl
    vault_agent_config = templatefile("${path.module}/templates/vault-agent/agent.hcl.tpl", {
      vault_addr      = var.vault_addr
      vault_namespace = var.vault_namespace
      approle_mount   = vault_auth_backend.approle.path
      cert_base_dir   = "C:\\Vault"
      exec_command    = jsonencode(["powershell.exe", "-File", "C:\\Vault\\hooks\\bind-cert.ps1"])
      exec_timeout    = "60s"
    })
  })

  tags = {
    Name        = "vault-demo-iis"
    Environment = var.environment
    Owner       = var.owner
    Platform    = "iis"
    ManagedBy   = "terraform"
  }
}
