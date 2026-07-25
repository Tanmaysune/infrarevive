# Architecture

## System Components

### 1. AWS Infrastructure (Terraform)
- **VPC** (172.20.0.0/16) with public subnet (172.20.5.0/24)
- **Internet Gateway** + route table for public access
- **Security Groups**: `jenkins-sg` (ports 22/80/8080/9090/9093) and `k8s-sg` (internal + SSH + 6443 + 9100 + NodePorts)
- **IAM Role** for Jenkins EC2 (ec2:*, s3:*, iam:PassRole) — enables Terraform to manage instances
- **EC2 Instances**:
  - Jenkins (t3.micro) — CI/CD + monitoring + dashboard host
  - K8s Master (c7i-flex.large) — control plane
  - 3× K8s Workers (t3.micro) — application workloads
- **S3 Backend** — `infrarevive-tfstate` bucket for remote Terraform state

### 2. Configuration Management (Ansible)
- **setup-master.yml**: yum update, swap off, kernel modules, sysctl, Docker, containerd, kubeadm init, Flannel CNI, kubeconfig, node-exporter
- **setup-workers.yml**: same base config + kubeadm join, node-exporter
- Idempotent: uses `creates:` guards on kubeadm init/join to prevent re-execution

### 3. CI/CD Pipeline (Jenkins Pipeline 1)
```
Checkout → Docker Build (api + frontend) → Push to DockerHub → kubectl apply manifests → Rolling Update → Verify
```
- Automatic rollback on failure (`kubectl rollout undo`)
- Cleans up local images in `post.always`

### 4. Recovery Pipeline (Jenkins Pipeline 2)
```
Alertmanager Webhook → Identify Dead Node → Terraform Destroy → Terraform Create → Update Prometheus → Wait SSH → Update Inventory → Get Join Command → Ansible Configure → Verify Ready → Verify Pods
```
- `disableConcurrentBuilds()` — prevents overlapping recoveries
- Targeted Terraform destroy/apply on specific worker index only
- `--limit <new_ip>` on Ansible — configures ONLY the new node, never healthy workers

### 5. Monitoring (Prometheus + Alertmanager + Node Exporter)
- **Node Exporter** (v1.7.0) installed on every K8s node via Ansible
- **Prometheus** scrapes node-exporter targets every 15s
- **Alert Rules**: NodeDown, InstanceDown, NodeHighCPU, NodeHighMemory, DiskFull, NodeNotReady
- **Alertmanager** routes critical alerts to Jenkins webhook → triggers Pipeline 2

### 6. Dashboard (Dark UI + Flask Backend)
- **Frontend**: Single-page HTML/CSS/JS app with 4 views (Dashboard, Nodes, Recovery, Alerts)
- **Dashboard API** (Flask, port 5001): proxies kubectl + aws CLI for browser
- **NGINX reverse proxy**: same-origin routing for all API calls

## Data Flow

```
Node Exporter (9100) ──scrape──→ Prometheus (9090) ──eval rules──→ Alertmanager (9093)
                                                                          │
                                                                          ▼ webhook
                                                                    Jenkins (8080)
                                                                          │
                                                                    Pipeline 2
                                                                          │
                                                              Terraform + Ansible
                                                                          │
                                                                    New EC2 Node
                                                                          │
                                                                    kubeadm join
                                                                          │
                                                                    Cluster Healed

Dashboard (browser) ──→ NGINX (80) ──→ /api/prometheus/ → Prometheus
                                  ──→ /api/jenkins/     → Jenkins
                                  ──→ /api/alertmanager/→ Alertmanager
                                  ──→ /api/dashboard/   → Dashboard API (5001)
                                                           ├── kubectl → Kubernetes API
                                                           └── aws cli → AWS EC2 API
```

## Network Topology

```
Internet
    │
    ▼
IGW → Public Subnet (172.20.5.0/24)
         │
    ┌────┼────────────────────┐
    ▼    ▼                    ▼
 Jenkins   K8s Master      3× K8s Workers
 (SG:jenkins) (SG:k8s)    (SG:k8s)
    │           │              │
    │      6443 API        NodePort
    │           │          30080/30500
    ▼           ▼              ▼
 Prometheus  kube-apiserver   App Pods
 Alertmanager    │
 NGINX       Flannel CNI (10.244.0.0/16)
 Dashboard       │
 Dashboard API   Pod networking
```
