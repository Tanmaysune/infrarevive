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

output "worker_private_ips" {
  value       = aws_instance.k8s_workers[*].private_ip
  description = "Worker node private IPs -- these are what kubelet registers as INTERNAL-IP in 'kubectl get nodes -o wide' (no cloud-controller-manager is installed in this project, so EXTERNAL-IP is always <none> and public IPs never appear in kubectl output). Recovery pipeline must match on this, not public IP."
}

output "worker_instance_ids" {
  value       = aws_instance.k8s_workers[*].id
  description = "Worker node instance IDs"
}
