variable "vault_addr" {
  description = "HCP Vault cluster address"
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace (default: admin)"
  type        = string
  default     = "admin"
}



variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "demo"
}

variable "cert_ttl" {
  description = "Certificate TTL (e.g. 720h for 30 days)"
  type        = string
  default     = "720h"
}

variable "cert_domain_linux" {
  description = "Common name for Linux server certs"
  type        = string
  default     = "apache.demo.internal"
}

variable "cert_domain_tomcat" {
  description = "Common name for Tomcat server certs"
  type        = string
  default     = "tomcat.demo.internal"
}

variable "cert_domain_windows" {
  description = "Common name for IIS server certs"
  type        = string
  default     = "iis.demo.internal"
}

variable "aws_region" {
  description = "AWS region for EC2 deployment"
  type        = string
  default     = "us-east-1"
}

variable "instance_type_linux" {
  description = "EC2 instance type for Linux servers"
  type        = string
  default     = "t3.small"
}

variable "instance_type_windows" {
  description = "EC2 instance type for Windows/IIS"
  type        = string
  default     = "t3.medium"
}
