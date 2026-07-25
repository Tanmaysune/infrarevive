# InfraRevive — Debian Linux Setup Guide

Complete step-by-step guide to install all dependencies and set up the InfraRevive Dead Server Recovery System from a Debian Linux machine.

**Tested on:** Debian 12 (Bookworm) / Debian 11 (Bullseye)

---

## Table of Contents

1. [Debian Control Machine — Install Dependencies](#1-debian-control-machine--install-dependencies)
2. [AWS Configuration](#2-aws-configuration)
3. [Project Setup](#3-project-setup)
4. [Provision AWS Infrastructure with Terraform](#4-provision-aws-infrastructure-with-terraform)
5. [Jenkins EC2 — Manual One-Time Setup](#5-jenkins-ec2--manual-one-time-setup)
6. [Configure IPs and Deploy Dashboard](#6-configure-ips-and-deploy-dashboard)
7. [Configure Kubernetes Cluster with Ansible](#7-configure-kubernetes-cluster-with-ansible)
8. [Deploy Application to Kubernetes](#8-deploy-application-to-kubernetes)
9. [Start All Services](#9-start-all-services)
10. [Configure Jenkins Pipelines](#10-configure-jenkins-pipelines)
11. [Verification Checklist](#11-verification-checklist)
12. [Ongoing Management (Start / Stop / Redeploy)](#12-ongoing-management-start--stop--redeploy)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Debian Control Machine — Install Dependencies

This is the machine from which you run Terraform, Ansible, and the shell scripts.

### 1.1 System Update

```bash
sudo apt update && sudo apt upgrade -y
```

### 1.2 Install Base Packages

```bash
sudo apt install -y \
    git \
    curl \
    wget \
    unzip \
    jq \
    python3 \
    python3-pip \
    openssh-client \
    ca-certificates \
    gnupg \
    lsb-release
```

### 1.3 Install AWS CLI v2

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
aws --version
```

### 1.4 Install Terraform

```bash
TERRAFORM_VERSION="1.6.6"
wget -O /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip /tmp/terraform.zip -d /tmp
sudo mv /tmp/terraform /usr/local/bin/
rm /tmp/terraform.zip
terraform --version
```

### 1.5 Install Ansible

```bash
sudo apt install -y ansible
ansible --version
```

### 1.6 Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

### 1.7 Install Docker (Optional — only needed for local docker-compose development)

```bash
# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add current user to docker group
sudo usermod -aG docker $USER
newgrp docker
docker --version
```

### 1.8 Verify All Tools

```bash
echo "=== Tool Versions ==="
aws --version
terraform --version
ansible --version
kubectl version --client
jq --version
git --version
```

---

## 2. AWS Configuration

### 2.1 Configure AWS Credentials

```bash
aws configure
```

When prompted, enter:

```
AWS Access Key ID:     <your-access-key>
AWS Secret Access Key: <your-secret-key>
Default region name:   us-east-1
Default output format: json
```

Verify:

```bash
aws sts get-caller-identity
```

### 2.2 Create EC2 Key Pair

Create a key pair named `infrarevive-key` in AWS (us-east-1) and save the private key:

```bash
# Option A: Create via AWS CLI
aws ec2 create-key-pair \
    --key-name infrarevive-key \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/infrarevive-key.pem

# Option B: Import an existing public key
# aws ec2 import-key-pair \
#     --key-name infrarevive-key \
#     --public-key-material fileb://~/.ssh/id_rsa.pub

# Set correct permissions
chmod 400 ~/.ssh/infrarevive-key.pem
```

### 2.3 Create S3 Bucket for Terraform State

The Terraform backend references the S3 bucket `infrarevive-tfstate`. This bucket **must exist** before `terraform init`. Create it manually:

```bash
aws s3api create-bucket \
    --bucket infrarevive-tfstate \
    --region us-east-1
```

> **Why manual?** Terraform's S3 backend needs the bucket to exist for `terraform init`, but the Terraform code also defines the bucket as a resource. We create it manually first, then import it into Terraform state (Step 4.2).

---

## 3. Project Setup

### 3.1 Clone the Repository

```bash
mkdir -p ~/project
cd ~/project
git clone https://github.com/Tanmaysune/infrarevive.git
cd infrarevive
```

> The project scripts expect the path `~/project/infrarevive`. If you clone elsewhere, create a symlink: `ln -s /your/path ~/project/infrarevive`

### 3.2 Review Terraform Variables

Check `terraform/variables.tf` and adjust if needed:

```bash
cat terraform/variables.tf
```

| Variable             | Default                  | Description                          |
|----------------------|--------------------------|--------------------------------------|
| `region`             | us-east-1                | AWS region                           |
| `instance_type_jenkins` | t3.micro              | Jenkins EC2 (2 vCPU, 1 GB RAM)      |
| `instance_type_master`  | c7i-flex.large         | K8s master (needs 2 vCPU, 4 GB RAM) |
| `instance_type_worker`  | t3.micro               | Worker nodes                         |
| `ami`                | ami-0c02fb55956c7d316    | Amazon Linux 2 AMI (us-east-1)       |
| `key_name`           | infrarevive-key          | EC2 key pair name                    |
| `worker_count`       | 3                        | Number of K8s worker nodes           |

> If the AMI `ami-0c02fb55956c316` is deprecated, find the latest Amazon Linux 2 AMI: `aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --region us-east-1 --query 'Parameters[0].Value' --output text`

### 3.3 Make Scripts Executable

```bash
chmod +x start-all.sh stop-all.sh setup-config.sh deploy-dashboard.sh
```

---

## 4. Provision AWS Infrastructure with Terraform

### 4.1 Initialize Terraform

```bash
cd ~/project/infrarevive/terraform
terraform init
```

### 4.2 Import S3 Bucket into Terraform State

Since we created the S3 bucket manually in Step 2.3, import it so Terraform knows about it:

```bash
terraform import aws_s3_bucket.tfstate infrarevive-tfstate
```

### 4.3 Apply Terraform

```bash
terraform plan -out tfplan
terraform apply tfplan
```

This creates:
- 1 VPC with public subnet (172.20.0.0/16)
- 1 Internet Gateway + Route Table
- 2 Security Groups (jenkins-sg, k8s-sg)
- 1 IAM Role + Policy + Instance Profile (for Jenkins EC2)
- 1 Jenkins EC2 (t3.micro)
- 1 K8s Master EC2 (c7i-flex.large)
- 3 K8s Worker EC2 (t3.micro)

### 4.4 Verify Outputs

```bash
terraform output
```

Expected output:

```
jenkins_public_ip = "xx.xx.xx.xx"
master_public_ip = "yy.yy.yy.yy"
worker_public_ips = [
  "zz.zz.zz.zz",
  "aa.aa.aa.aa",
  "bb.bb.bb.bb",
]
worker_private_ips = [...]
```

Save these IPs — you'll need them in the next steps.

```bash
cd ~/project/infrarevive
```

---

## 5. Jenkins EC2 — Manual One-Time Setup

The Jenkins EC2 instance needs Jenkins, Prometheus, Alertmanager, Docker, kubectl, and other tools installed. This is a **one-time setup** — after this, `start-all.sh` handles reconfiguration on restarts.

### 5.1 SSH into Jenkins EC2

```bash
# Get Jenkins EC2 IP from Terraform output
JENKINS_IP=$(cd terraform && terraform output -raw jenkins_public_ip)
echo "Jenkins EC2 IP: $JENKINS_IP"

ssh -i ~/.ssh/infrarevive-key.pem ec2-user@$JENKINS_IP
```

### 5.2 Install System Packages

```bash
# On Jenkins EC2 (Amazon Linux 2 — uses yum, not apt)
sudo yum update -y
sudo yum install -y yum-utils curl wget tar python3 python3-pip jq
```

### 5.3 Install Jenkins

```bash
sudo wget -O /etc/yum.repos.d/jenkins.repo \
    https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins java-17-openjdk-devel
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

Get the initial admin password:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### 5.4 Install Docker

```bash
sudo yum install -y docker
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker jenkins
sudo usermod -aG docker ec2-user
```

### 5.5 Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
```

### 5.6 Install AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
```

Configure AWS CLI on Jenkins EC2 (same credentials as your Debian machine):

```bash
sudo su - jenkins
aws configure
# Enter the same AWS Access Key, Secret Key, region (us-east-1), output (json)
exit
```

### 5.7 Install Terraform on Jenkins EC2

```bash
sudo yum-config-manager --add-repo \
    https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install -y terraform
```

### 5.8 Install Ansible on Jenkins EC2

```bash
sudo yum install -y ansible
```

### 5.9 Install Prometheus

```bash
# Create prometheus user
sudo useradd --no-create-home --shell /bin/false prometheus

# Download and install
cd /tmp
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xzf prometheus-2.45.0.linux-amd64.tar.gz
sudo cp prometheus-2.45.0.linux-amd64/prometheus /usr/local/bin/
sudo cp prometheus-2.45.0.linux-amd64/promtool /usr/local/bin/
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /usr/local/bin/prometheus
sudo chown prometheus:prometheus /usr/local/bin/promtool
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Create systemd service
sudo tee /etc/systemd/system/prometheus.service > /dev/null << 'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --web.listen-address=0.0.0.0:9090

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable prometheus
rm -rf /tmp/prometheus-*
```

### 5.10 Install Alertmanager

```bash
# Create alertmanager user
sudo useradd --no-create-home --shell /bin/false alertmanager

# Download and install
cd /tmp
wget https://github.com/prometheus/alertmanager/releases/download/v0.26.0/alertmanager-0.26.0.linux-amd64.tar.gz
tar xzf alertmanager-0.26.0.linux-amd64.tar.gz
sudo cp alertmanager-0.26.0.linux-amd64/alertmanager /usr/local/bin/
sudo cp alertmanager-0.26.0.linux-amd64/amtool /usr/local/bin/
sudo mkdir -p /etc/prometheus /var/lib/alertmanager
sudo chown alertmanager:alertmanager /usr/local/bin/alertmanager
sudo chown -R alertmanager:alertmanager /var/lib/alertmanager

# Create systemd service
sudo tee /etc/systemd/system/alertmanager.service > /dev/null << 'EOF'
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/prometheus/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=0.0.0.0:9093

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable alertmanager
rm -rf /tmp/alertmanager-*
```

> **Note:** Alertmanager config is deployed to `/etc/prometheus/alertmanager.yml` (not `/etc/alertmanager/`) by the project scripts. The systemd service above matches this path.

### 5.11 Install NGINX

```bash
sudo yum install -y nginx
sudo systemctl enable nginx
sudo mkdir -p /usr/share/nginx/html/infrarevive
```

### 5.12 Create kubeconfig Directory for Jenkins

```bash
sudo mkdir -p /var/lib/jenkins/.kube
sudo chown jenkins:jenkins /var/lib/jenkins/.kube
```

### 5.13 Exit Jenkins EC2

```bash
exit
```

You are now back on your Debian machine.

---

## 6. Configure IPs and Deploy Dashboard

### 6.1 Run setup-config.sh

```bash
cd ~/project/infrarevive
./setup-config.sh
```

This script:
- Fetches EC2 IPs from Terraform output
- Creates `.env` with real IPs
- Fills `ansible/inventory.ini` with real IPs
- Fills `prometheus/prometheus.yml` with real IPs
- Deploys the dashboard (HTML) to Jenkins EC2 via NGINX
- Deploys the dashboard-api (Flask) to Jenkins EC2 as a systemd service
- Deploys `alertmanager.yml` to Jenkins EC2

### 6.2 Verify Generated Files

```bash
cat .env
cat ansible/inventory.ini
cat prometheus/prometheus.yml
```

---

## 7. Configure Kubernetes Cluster with Ansible

### 7.1 Configure K8s Master

```bash
cd ~/project/infrarevive
ansible-playbook -i ansible/inventory.ini ansible/setup-master.yml
```

This installs on the master node:
- Docker + containerd (with SystemdCgroup)
- kubeadm, kubelet, kubectl (v1.29)
- Kernel modules (overlay, br_netfilter) — persisted
- sysctl params — applied immediately
- iproute-tc
- Flannel CNI v0.28.5
- Node Exporter v1.7.0
- Runs `kubeadm init` (idempotent — guarded by `creates: /etc/kubernetes/admin.conf`)
- Saves the join command

> **Duration:** ~5-8 minutes. Wait for it to complete.

### 7.2 Get kubeconfig from Master

```bash
MASTER_IP=$(grep -A1 '\[k8s_master\]' ansible/inventory.ini | tail -1 | awk '{print $1}')
scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    ec2-user@$MASTER_IP:/home/ec2-user/.kube/config ~/.kube/config
sed -i "s|server: https://.*:6443|server: https://$MASTER_IP:6443|" ~/.kube/config
```

Verify:

```bash
kubectl get nodes
```

You should see the master node in `Ready` state.

### 7.3 Configure K8s Workers

```bash
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml
```

This installs on each worker node:
- Docker + containerd
- kubeadm, kubelet, kubectl (v1.29)
- Kernel modules — persisted
- sysctl — applied immediately
- iproute-tc
- Node Exporter v1.7.0
- Runs `kubeadm join` (idempotent — guarded by `creates: /etc/kubernetes/kubelet.conf`)

> **Duration:** ~5-10 minutes for all workers.

### 7.4 Verify All Nodes

```bash
kubectl get nodes -o wide
```

Expected:

```
NAME                          STATUS   ROLES           AGE   VERSION
ip-172-20-5-xxx.ec2.internal  Ready    control-plane   10m   v1.29.x
ip-172-20-5-yyy.ec2.internal  Ready    <none>          5m    v1.29.x
ip-172-20-5-zzz.ec2.internal  Ready    <none>          5m    v1.29.x
ip-172-20-5-www.ec2.internal  Ready    <none>          5m    v1.29.x
```

---

## 8. Deploy Application to Kubernetes

### 8.1 Apply Kubernetes Manifests

```bash
cd ~/project/infrarevive

kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/persistent-volume.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
```

> Skip `kubernetes/ingress.yaml` unless you have an Ingress Controller installed.

### 8.2 Wait for Pods to Be Ready

```bash
kubectl wait --for=condition=Ready pod --all -n infrarevive --timeout=180s
kubectl get pods -n infrarevive -o wide
```

### 8.3 Initialize Database

```bash
WORKER0_IP=$(grep 'WORKER0_IP' .env | cut -d= -f2)
curl http://$WORKER0_IP:30500/init-db
```

Expected response:

```json
{"status": "Database initialized with sample data"}
```

---

## 9. Start All Services

### 9.1 Run start-all.sh

```bash
cd ~/project/infrarevive
./start-all.sh
```

This script:
- Ensures all EC2 instances are running
- Fetches current public IPs (EC2 instances get new IPs on restart)
- Regenerates `.env`, `inventory.ini`, and `prometheus.yml` with fresh IPs
- Regenerates the Kubernetes API server certificate for the new master IP
- Syncs kubeconfig to the Jenkins EC2 (for Jenkins pipelines)
- Ensures Flannel CNI is healthy
- Restarts Prometheus and Alertmanager on Jenkins EC2
- Deploys alertmanager.yml to Jenkins EC2
- Deploys dashboard + dashboard-api to Jenkins EC2
- Cleans up stale/Unknown pods
- Waits for all pods to be Ready

### 9.2 Note the Access URLs

At the end of the script, you'll see:

```
Jenkins   : http://<JENKINS_IP>:8080
Prometheus: http://<JENKINS_IP>:9090
App       : http://<WORKER0_IP>:30080
API       : http://<WORKER0_IP>:30500

================================================
DASHBOARD  : http://<JENKINS_IP>/infrarevive/
================================================
```

---

## 10. Configure Jenkins Pipelines

### 10.1 Access Jenkins

Open `http://<JENKINS_IP>:8080` in your browser.

1. Enter the initial admin password (from Step 5.3, or run: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` on Jenkins EC2)
2. Install suggested plugins
3. Create admin user

### 10.2 Install Required Plugins

Go to **Manage Jenkins → Plugins → Available plugins** and install:

- **Generic Webhook Trigger** — for the recovery pipeline webhook trigger
- **Pipeline** — (usually pre-installed)
- **Git** — (usually pre-installed)
- **Docker Pipeline** — for building images

### 10.3 Add DockerHub Credentials

Go to **Manage Jenkins → Credentials → System → Global credentials → Add credentials**:

- **Kind:** Username with password
- **Username:** `sune21tanmay` (or your DockerHub username)
- **Password:** `<your-dockerhub-password-or-token>`
- **ID:** `dockerhub-credentials`
- **Description:** DockerHub credentials for image push

### 10.4 Create CI/CD Pipeline (Pipeline 1)

1. **New Item → Pipeline**
2. **Name:** `infrarevive-cicd`
3. **Definition:** Pipeline script from SCM
4. **SCM:** Git
5. **Repository URL:** `https://github.com/Tanmaysune/infrarevive.git`
6. **Branch:** `*/main`
7. **Script Path:** `Jenkinsfile-CICD`
8. **Save**

### 10.5 Create Recovery Pipeline (Pipeline 2)

1. **New Item → Pipeline**
2. **Name:** `infrarevive-recovery`
3. **Definition:** Pipeline script from SCM
4. **SCM:** Git
5. **Repository URL:** `https://github.com/Tanmaysune/infrarevive.git`
6. **Branch:** `*/main`
7. **Script Path:** `Jenkinsfile-Recovery`
8. **Save**

### 10.6 Configure Generic Webhook Trigger for Recovery Pipeline

1. Open `infrarevive-recovery` pipeline → **Configure**
2. Under **Build Triggers**, check **Generic Webhook Trigger**
3. **Token:** `INFRAREVIVE_RECOVERY_TOKEN`
4. **Save**

The Alertmanager webhook URL is:
```
http://localhost:8080/generic-webhook-trigger/invoke?token=INFRAREVIVE_RECOVERY_TOKEN
```

### 10.7 (Optional) Configure GitHub Webhook for CI/CD

In your GitHub repository settings:
- **Payload URL:** `http://<JENKINS_IP>:8080/github-webhook/`
- **Content type:** `application/json`
- **Trigger:** On push to main

### 10.8 Test CI/CD Pipeline

Run the `infrarevive-cicd` pipeline manually (click **Build Now**). This will:
1. Build Docker images (flask-api + frontend)
2. Push to DockerHub (`sune21tanmay/infrarevive-api` and `sune21tanmay/infrarevive-frontend`)
3. Deploy to Kubernetes with rolling update
4. Auto-rollback on failure

---

## 11. Verification Checklist

### 11.1 Infrastructure

```bash
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=infrarevive-*" \
    --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress]' \
    --output table
```

Expected: 5 instances (jenkins, master, 3 workers) all in `running` state.

### 11.2 Kubernetes

```bash
kubectl get nodes -o wide
kubectl get pods -n infrarevive -o wide
kubectl get services -n infrarevive
```

Expected: All nodes `Ready`, all pods `Running`, services showing NodePorts 30500 and 30080.

### 11.3 Monitoring

```bash
# Check Prometheus targets
curl -s http://<JENKINS_IP>:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Check Alertmanager status
curl -s http://<JENKINS_IP>:9093/api/v2/status | jq '.versionInfo.version'
```

Expected: All targets `up` (prometheus, node-exporter, flask-api).

### 11.4 Dashboard

Open in browser: `http://<JENKINS_IP>/infrarevive/`

Verify:
- Cluster status bar shows correct node count
- Service cards show green (running) for Jenkins, Prometheus, Alertmanager, NGINX, Docker
- Node table shows all nodes with real IPs
- Metric graphs show real data (CPU, RAM, Disk, Network)
- Recovery timeline shows pipeline history

### 11.5 Application

```bash
# Test API health
curl http://<WORKER0_IP>:30500/health

# Test API metrics (Prometheus scrape endpoint)
curl http://<WORKER0_IP>:30500/metrics

# Test database query
curl http://<WORKER0_IP>:30500/result/Alice

# Open frontend in browser
# http://<WORKER0_IP>:30080
```

---

## 12. Ongoing Management (Start / Stop / Redeploy)

### 12.1 Stop All Resources

```bash
cd ~/project/infrarevive
./stop-all.sh
```

This:
- Stops dashboard-api, Prometheus, Alertmanager, NGINX on Jenkins EC2
- Clears `.env` (prevents stale IP reuse)
- Stops all EC2 instances
- S3 bucket and Terraform state are untouched

> EC2 instances take 30-60 seconds to fully stop. You are not charged for compute while stopped (only for EBS volumes).

### 12.2 Start All Resources

```bash
cd ~/project/infrarevive
./start-all.sh
```

This brings everything back up with fresh IPs and reconfigures all services. No manual intervention needed.

### 12.3 Redeploy Dashboard Only

If you only changed the dashboard HTML or dashboard-api code:

```bash
cd ~/project/infrarevive
./deploy-dashboard.sh
```

### 12.4 Trigger CI/CD Manually

Push to the `main` branch on GitHub, or click **Build Now** in Jenkins on the `infrarevive-cicd` pipeline.

### 12.5 Test Recovery Pipeline

To simulate a dead worker node (for testing recovery):

```bash
# Find a worker instance ID
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=infrarevive-worker-0" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text

# Terminate it (simulates hardware failure)
aws ec2 terminate-instances --instance-ids <worker-0-instance-id>
```

Within 30 seconds, Prometheus detects the missing node-exporter, Alertmanager fires the webhook, and Jenkins Pipeline 2 automatically:
1. Identifies the dead worker
2. Destroys the dead EC2 via Terraform
3. Creates a fresh EC2 via Terraform
4. Updates Prometheus targets
5. Configures the new node via Ansible
6. Verifies the cluster is healthy

**Total recovery time: under 5 minutes.**

---

## 13. Troubleshooting

### Terraform Init Fails — S3 Bucket Not Found

```
Error: Failed to get existing workspaces: BucketNotFound
```

**Fix:** Create the S3 bucket first:
```bash
aws s3api create-bucket --bucket infrarevive-tfstate --region us-east-1
```

### Terraform Apply Fails — BucketAlreadyExists

```
Error: creating Amazon S3 (Simple Storage) Bucket: BucketAlreadyExists
```

**Fix:** Import the existing bucket into Terraform state:
```bash
cd terraform
terraform import aws_s3_bucket.tfstate infrarevive-tfstate
terraform apply -auto-approve
```

### Ansible Fails — SSH Connection Refused

```
UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```

**Fix:** Verify the key pair and security group:
```bash
# Test SSH manually
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<MASTER_IP>

# Check security group allows SSH from your IP
aws ec2 describe-security-groups --group-ids <sg-id> --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`]'
```

### kubectl Cannot Connect to Cluster

```
The connection to the server <ip>:6443 was refused
```

**Fix:** Regenerate kubeconfig after EC2 restart (IPs change):
```bash
./start-all.sh  # This regenerates kubeconfig with new IPs
```

### Pods Stuck in ContainerCreating

```
Warning: FailedScheduling ... node(s) had volume node affinity conflict
```

**Fix:** MySQL is pinned to the master node. Ensure the master is `Ready`:
```bash
kubectl get nodes
kubectl describe pod -n infrarevive -l app=mysql
```

### Prometheus Target Showing as Down

```
flask-api (1/1 down)
```

**Fix:** The Flask app needs the `/metrics` endpoint. Verify:
```bash
curl http://<WORKER0_IP>:30500/metrics
# Should return: flask_api_up 1
```

If empty, rebuild and redeploy the Docker image via the CI/CD pipeline.

### Dashboard Shows No Data

**Fix:**
1. Check the dashboard-api is running: `curl http://<JENKINS_IP>:5001/health`
2. Check NGINX proxy: `curl http://<JENKINS_IP>/api/dashboard/health`
3. Rerun: `./deploy-dashboard.sh`

### Recovery Pipeline Fails — Worker IPs Not Valid

```
Worker IPs never became valid after 10 attempts
```

**Fix:** Verify Terraform state is current:
```bash
cd terraform
terraform init -reconfigure
terraform refresh
terraform output
```

---

## Quick Reference — File Locations

| File | Location on Debian Machine | Purpose |
|------|---------------------------|---------|
| Project root | `~/project/infrarevive/` | All project files |
| SSH key | `~/.ssh/infrarevive-key.pem` | EC2 SSH access |
| kubeconfig | `~/.kube/config` | Kubernetes access |
| .env | `~/project/infrarevive/.env` | Current EC2 IPs (auto-generated) |
| Ansible inventory | `~/project/infrarevive/ansible/inventory.ini` | K8s node IPs (auto-generated) |
| Prometheus config | `~/project/infrarevive/prometheus/prometheus.yml` | Scrape targets (auto-generated) |
| Terraform state | S3: `infrarevive-tfstate/state/terraform.tfstate` | Infrastructure state |

## Quick Reference — Ports

| Service       | Port  | Access |
|---------------|-------|--------|
| Jenkins       | 8080  | `http://<JENKINS_IP>:8080` |
| Prometheus    | 9090  | `http://<JENKINS_IP>:9090` |
| Alertmanager  | 9093  | `http://<JENKINS_IP>:9093` |
| Dashboard     | 80    | `http://<JENKINS_IP>/infrarevive/` |
| Dashboard API | 5001  | Jenkins EC2 only (proxied via NGINX) |
| Flask API     | 30500 | `http://<WORKER_IP>:30500` (NodePort) |
| Frontend      | 30080 | `http://<WORKER_IP>:30080` (NodePort) |
| K8s API       | 6443  | Master EC2 only |
| Node Exporter | 9100  | All EC2 instances |
| SSH           | 22    | All EC2 instances |

## Quick Reference — Commands

```bash
# Start everything
cd ~/project/infrarevive && ./start-all.sh

# Stop everything
cd ~/project/infrarevive && ./stop-all.sh

# Redeploy dashboard only
cd ~/project/infrarevive && ./deploy-dashboard.sh

# Reconfigure IPs from Terraform (one-time)
cd ~/project/infrarevive && ./setup-config.sh

# Check cluster status
kubectl get nodes -o wide
kubectl get pods -n infrarevive -o wide

# Check EC2 status
aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-*" \
    --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],State.Name]' \
    --output table
```
