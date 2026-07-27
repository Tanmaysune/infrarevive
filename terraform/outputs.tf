output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Jenkins server public IP"
}

output "jenkins_instance_id" {
  value       = aws_instance.jenkins.id
  description = "Jenkins instance ID -- use this instead of tag-based lookups, which can match stale/terminated instances sharing the same Name tag after a destroy/recreate."
}

output "master_public_ip" {
  value       = aws_instance.k8s_master.public_ip
  description = "Kubernetes master public IP"
}

output "master_instance_id" {
  value       = aws_instance.k8s_master.id
  description = "Kubernetes master instance ID -- use this instead of tag-based lookups, same reason as jenkins_instance_id."
}

output "master_private_ip" {
  value       = aws_instance.k8s_master.private_ip
  description = "Kubernetes master private IP -- stable across stop/start (only changes if the instance is recreated). Use this for Prometheus scrape targets instead of the public IP."
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

