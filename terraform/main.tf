provider "aws" {
  region = var.region
}

terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket = "infrarevive-tfstate"
    key    = "state/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "infrarevive-terraform-locks"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "172.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "infrarevive-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "infrarevive-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.20.5.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "infrarevive-public" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "infrarevive-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "jenkins_sg" {
  name        = "infrarevive-jenkins-sg"
  description = "Jenkins security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Jenkins UI"
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Prometheus"
  }

  ingress {
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Alertmanager"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Dashboard"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "infrarevive-jenkins-sg" }
}

resource "aws_security_group" "k8s_sg" {
  name        = "infrarevive-k8s-sg"
  description = "Kubernetes cluster security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["172.20.0.0/16"]
    description = "All internal"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH for Ansible"
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kubernetes API server"
  }

  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Node Exporter"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "NodePort apps"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "infrarevive-k8s-sg" }
}

resource "aws_iam_role" "jenkins_role" {
  name = "infrarevive-jenkins-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_policy" {
  name = "infrarevive-jenkins-policy"
  role = aws_iam_role.jenkins_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ec2:*",
        "s3:*",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "iam:PassRole",
        "iam:GetRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:GetRolePolicy",
        "iam:GetInstanceProfile"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "infrarevive-jenkins-profile"
  role = aws_iam_role.jenkins_role.name
}

resource "aws_iam_role" "cluster_node_role" {
  name = "infrarevive-cluster-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The EBS CSI controller uses the node role to provision durable MySQL volumes.
resource "aws_iam_role_policy_attachment" "cluster_node_ebs_csi" {
  role       = aws_iam_role.cluster_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicyV2"
}

resource "aws_iam_instance_profile" "cluster_node_profile" {
  name = "infrarevive-cluster-node-profile"
  role = aws_iam_role.cluster_node_role.name
}

resource "aws_instance" "jenkins" {
  ami                    = var.ami
  instance_type          = var.instance_type_jenkins
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name
  root_block_device { volume_size = 20 }
  tags = {
    Name    = "infrarevive-jenkins"
    Project = "infrarevive"
    Role    = "jenkins"
  }
}

resource "aws_instance" "k8s_master" {
  ami                    = var.ami
  instance_type          = var.instance_type_master
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cluster_node_profile.name
  root_block_device { volume_size = 20 }
  tags = {
    Name    = "infrarevive-master"
    Project = "infrarevive"
    Role    = "master"
  }
}

resource "aws_instance" "k8s_workers" {
  count                  = var.worker_count
  ami                    = var.ami
  instance_type          = var.instance_type_worker
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cluster_node_profile.name
  root_block_device { volume_size = 15 }
  tags = {
    Name    = "infrarevive-worker-${count.index}"
    Project = "infrarevive"
    Role    = "worker"
  }
}

# Kept in the existing state until the backend is migrated to a dedicated
# bootstrap state. The lifecycle guard prevents accidental state-bucket deletion.
resource "aws_s3_bucket" "tfstate" {
  bucket = "infrarevive-tfstate"

  lifecycle {
    prevent_destroy = true
  }
}
