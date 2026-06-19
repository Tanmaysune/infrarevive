output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Jenkins server public IP"
}

output "master_public_ip" {
  value       = aws_instance.k8s_master.public_ip
  description = "Kubernetes master public IP"
}

output "worker_public_ips" {
  value       = aws_instance.k8s_workers[*].public_ip
  description = "Worker node public IPs"
}

output "worker_instance_ids" {
  value       = aws_instance.k8s_workers[*].id
  description = "Worker node instance IDs (needed for recovery targeting)"
}
