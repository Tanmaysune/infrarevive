# Setup Guide

## Prerequisites

### Local Machine
Install these tools:
```bash
# Terraform
curl -O https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
unzip terraform_1.6.6_linux_amd64.zip && sudo mv terraform /usr/local/bin/

# Ansible
sudo yum install -y ansible   # or: pip3 install ansible

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# jq (for parsing terraform output JSON)
sudo yum install -y jq
```

### AWS Configuration
```bash
aws configure
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region:        us-east-1
# Default output format: json
```

### EC2 Key Pair
Create a key pair named `infrarevive-key` in AWS Console (us-east-1).
Save the `.pem` file to `~/.ssh/infrarevive-key.pem` and set permissions:
```bash
chmod 400 ~/.ssh/infrarevive-key.pem
```

### DockerHub
Create a DockerHub account. Note your username for the Jenkinsfile:
- Update `DOCKERHUB_USERNAME` in `Jenkinsfile-CICD`

### GitHub
1. Fork or create the repository
2. Update the `git url` in `Jenkinsfile-CICD` to your repo
3. Add a webhook: `http://<JENKINS_IP>:8080/github-webhook/` (after Jenkins is up)

## Terraform Variables

Review and customize `terraform/variables.tf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | us-east-1 | AWS region |
| `instance_type_jenkins` | t3.micro | Jenkins EC2 size |
| `instance_type_master` | c7i-flex.large | K8s master size (needs 2 vCPU, 4GB) |
| `instance_type_worker` | t3.micro | Worker node size |
| `ami` | ami-0c02fb55956c7d316 | Amazon Linux 2 AMI |
| `key_name` | infrarevive-key | EC2 key pair name |
| `worker_count` | 3 | Number of K8s worker nodes |

## Initial Setup Steps

1. **Provision infrastructure**: `cd terraform && terraform init && terraform apply -auto-approve`
2. **Configure IPs**: `cd .. && ./setup-config.sh`
3. **Set up Kubernetes**: Run Ansible playbooks (master then workers)
4. **Deploy app**: `kubectl apply -f kubernetes/`
5. **Start monitoring**: `./start-all.sh`
6. **Configure Jenkins**: See [Deployment Guide](DEPLOYMENT.md) Phase 6

## Jenkins EC2 Manual Setup (first time only)

SSH into Jenkins EC2 and install:
```bash
# Jenkins
sudo yum update -y
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins java-17-openjdk
sudo systemctl enable jenkins && sudo systemctl start jenkins

# Docker
sudo yum install -y docker
sudo systemctl enable docker && sudo systemctl start docker
sudo usermod -aG docker jenkins

# Terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install -y terraform

# Ansible
sudo yum install -y ansible

# kubectl
curl -LO https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# AWS CLI
sudo ./aws/install   # from the bundled aws/ directory

# Prometheus
sudo useradd --no-create-home --shell /bin/false prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xzf prometheus-2.45.0.linux-amd64.tar.gz
sudo cp prometheus-2.45.0.linux-amd64/prometheus /usr/local/bin/
sudo mkdir -p /etc/prometheus /var/lib/prometheus
# Copy prometheus.yml and alert.rules.yml to /etc/prometheus/
# Create systemd service for prometheus

# Alertmanager
wget https://github.com/prometheus/alertmanager/releases/download/v0.26.0/alertmanager-0.26.0.linux-amd64.tar.gz
tar xzf alertmanager-0.26.0.linux-amd64.tar.gz
sudo cp alertmanager-0.26.0.linux-amd64/alertmanager /usr/local/bin/
sudo mkdir -p /etc/alertmanager
# Copy alertmanager.yml to /etc/alertmanager/
# Create systemd service for alertmanager
```
