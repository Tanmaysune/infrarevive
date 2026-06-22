variable "region" {
  default     = "us-east-1"
  description = "AWS region"
}

variable "instance_type_jenkins" {
  default     = "t3.micro"
  description = "Jenkins EC2 - free tier - 2 vCPU 1GB RAM"
}

variable "instance_type_master" {
  default     = "c7i-flex.large"
  description = "K8s Master - free tier - 2 vCPU 4GB RAM needed for Kubernetes"
}

variable "instance_type_worker" {
  default     = "t3.micro"
  description = "Worker nodes - free tier - 2 vCPU 1GB RAM"
}

variable "ami" {
  default     = "ami-0c02fb55956c7d316"
  description = "Amazon Linux 2 AMI for us-east-1"
}

variable "key_name" {
  default     = "infrarevive-key"
  description = "EC2 key pair name"
}

variable "worker_count" {
  default     = 3
  description = "Number of Kubernetes worker nodes"
}
