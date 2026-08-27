output "app_public_ip" {
  description = "Elastic IP of the application host — the Cloudflare A record's target (proxied)."
  value       = aws_eip.app.public_ip
}

output "app_instance_id" {
  description = "For `aws ssm start-session --target` and `ssm send-command`."
  value       = aws_instance.app.id
}

output "app_hostname" {
  value = var.app_hostname
}
