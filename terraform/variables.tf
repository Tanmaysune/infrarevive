variable "region" {
  default     = "us-east-1"
  description = "AWS region"
}

variable "instance_type_small" {
  default     = "t2.micro"
  description = "Jenkins and worker node instance type"
}

variable "instance_type_medium" {
  default     = "t2.medium"
  description = "Kubernetes master instance type"
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
