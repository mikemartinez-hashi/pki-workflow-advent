output "apache_instance_id" {
  description = "Apache EC2 instance ID"
  value       = aws_instance.apache.id
}

output "apache_private_ip" {
  description = "Apache instance private IP"
  value       = aws_instance.apache.private_ip
}

output "tomcat_instance_id" {
  description = "Tomcat EC2 instance ID"
  value       = aws_instance.tomcat.id
}

output "tomcat_private_ip" {
  description = "Tomcat instance private IP"
  value       = aws_instance.tomcat.private_ip
}

output "iis_instance_id" {
  description = "IIS (Windows) EC2 instance ID"
  value       = aws_instance.iis.id
}

output "iis_private_ip" {
  description = "IIS instance private IP"
  value       = aws_instance.iis.private_ip
}

output "ssm_connect_apache" {
  description = "SSM session command for Apache instance"
  value       = "aws ssm start-session --target ${aws_instance.apache.id} --region ${var.aws_region}"
}

output "ssm_connect_tomcat" {
  description = "SSM session command for Tomcat instance"
  value       = "aws ssm start-session --target ${aws_instance.tomcat.id} --region ${var.aws_region}"
}

output "ssm_connect_iis" {
  description = "SSM session command for IIS instance"
  value       = "aws ssm start-session --target ${aws_instance.iis.id} --region ${var.aws_region}"
}

output "verify_commands" {
  description = "Quick reference verification commands"
  value       = <<-EOT
    # Apache
    aws ssm start-session --target ${aws_instance.apache.id}
    systemctl status vault-agent
    openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -subject -issuer -dates

    # Tomcat
    aws ssm start-session --target ${aws_instance.tomcat.id}
    systemctl status vault-agent
    openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -subject -issuer -dates

    # IIS (Windows)
    aws ssm start-session --target ${aws_instance.iis.id}
    Get-Service VaultAgent
    Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, NotAfter
  EOT
}

output "manual_role_id" {
  description = "AppRole Role ID for manual/existing server enrollment"
  value       = vault_approle_auth_backend_role.roles["manual"].role_id
}

output "manual_secret_id" {
  description = "AppRole Secret ID for manual/existing server enrollment"
  value       = vault_approle_auth_backend_role_secret_id.secret_ids["manual"].secret_id
  sensitive   = true
}
