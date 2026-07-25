# INFRAREVIVE — Dead Server Recovery System

A production-grade DevOps platform that **automatically detects, destroys, and replaces failed Kubernetes worker nodes on AWS** — with zero human intervention and a recovery time under 5 minutes.

The system combines **Terraform** (infrastructure as code), **Ansible** (configuration management), **Jenkins** (CI/CD + recovery pipelines), **Prometheus + Alertmanager** (monitoring + alerting), and a **real-time dark monitoring dashboard** that shows live AWS, Kubernetes, and Prometheus metrics.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        NORMAL CI/CD PIPELINE                            │
│                                                                         │
│  Developer → GitHub → Webhook → Jenkins Pipeline 1 (CI/CD)             │
│       → Docker Build → Push to DockerHub → Deploy to Kubernetes         │
│       → Running Application (NGINX + Flask + MySQL)                     │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                      AUTOMATIC RECOVERY PIPELINE                        │
│                                                                         │
│  Worker Node Fails                                                      │
│       → Prometheus detects (node-exporter down)                         │
│       → Alertmanager triggers webhook                                   │
│       → Jenkins Pipeline 2 (Recovery) starts                            │
│       → Terraform destroys dead EC2                                     │
│       → Terraform creates new EC2                                       │
│       → Ansible configures node (Docker, kubeadm, kubelet, kubectl)     │
│       → Node joins Kubernetes cluster                                    │
│       → Pods automatically rescheduled                                  │
│       → Recovery Complete (< 5 minutes)                                  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    REAL-TIME MONITORING DASHBOARD                       │
│                                                                         │
│  Dark professional UI served via NGINX on Jenkins EC2                   │
│  Data sources: Prometheus API · Kubernetes API · AWS API ·              │
│                Jenkins API · Alertmanager API · Node Exporter           │
│  No dummy data — everything is real.                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
infrarevive/
├── ansible/                    # Ansible playbooks for node configuration
│   ├── inventory.ini           # Auto-generated inventory with real EC2 IPs
│   ├── setup-master.yml        # Master node: kubeadm init, Flannel, node-exporter
│   └── setup-workers.yml       # Worker nodes: Docker, kubeadm join, node-exporter
├── ansible.cfg                 # Ansible configuration (SSH, Python interpreter)
├── app/                        # Flask backend API (Student Result Portal)
│   ├── app.py                  # Flask app with /health, /result, /init-db endpoints
│   ├── Dockerfile              # Python 3.11-slim based image
│   └── requirements.txt        # flask, flask-cors, mysql-connector-python
├── aws/                        # Bundled AWS CLI v2 installer (for Jenkins EC2)
├── dashboard/                  # Real-time monitoring dashboard (dark UI)
│   └── index.html              # Single-page app: cluster status, nodes, graphs, recovery
├── dashboard-api/              # Backend API for dashboard (AWS + K8s data)
│   ├── app.py                  # Flask API: /api/k8s/*, /api/aws/*, /api/system/*
│   ├── requirements.txt        # flask, flask-cors
│   ├── Dockerfile              # Container build option
│   └── dashboard-api.service   # systemd unit for Jenkins EC2
├── docker-compose.yml          # Local development: flask-api + frontend + mysql
├── frontend/                   # NGINX-served static frontend
│   ├── index.html              # Student Result Portal UI
│   └── Dockerfile              # nginx:alpine based image
├── Jenkinsfile-CICD            # Pipeline 1: Build → Push → Deploy (rolling update)
├── Jenkinsfile-Recovery        # Pipeline 2: Detect → Destroy → Create → Configure → Join
├── kubernetes/                 # Kubernetes manifests
│   ├── namespace.yaml          # infrarevive namespace
│   ├── configmap.yaml          # Non-sensitive app config (DB_HOST, DB_USER, etc.)
│   ├── secret.yaml             # Sensitive credentials (base64-encoded)
│   ├── deployment.yaml         # flask-api, frontend, mysql deployments
│   ├── service.yaml            # NodePort + ClusterIP services
│   ├── persistent-volume.yaml  # PV + PVC for MySQL
│   ├── ingress.yaml            # Ingress routing (frontend + API)
│   └── kube-flannel.yaml       # Flannel CNI manifest
├── nginx/                      # NGINX reverse proxy config (dashboard + API proxies)
│   └── infrarevive-nginx.conf  # Proxies: /api/jenkins, /api/prometheus, /api/alertmanager, /api/dashboard
├── prometheus/                 # Monitoring configuration
│   ├── prometheus.yml          # Scrape config (node-exporter, flask-api)
│   ├── alert.rules.yml         # NodeDown, InstanceDown, HighCPU, HighMemory, DiskFull, NodeNotReady
│   └── alertmanager.yml        # Webhook to Jenkins recovery trigger
├── terraform/                  # AWS infrastructure as code
│   ├── main.tf                 # VPC, subnets, SGs, IAM, EC2, S3 backend
│   ├── variables.tf            # Region, instance types, AMI, key name, worker count
│   └── outputs.tf              # Public/private IPs, instance IDs
├── docs/                       # Documentation
│   ├── ARCHITECTURE.md
│   ├── DEPLOYMENT.md
│   ├── SETUP.md
│   ├── RECOVERY-FLOW.md
│   ├── DASHBOARD.md
│   ├── API.md
│   ├── PIPELINES.md
│   └── TROUBLESHOOTING.md
├── .env                        # Auto-generated IPs (created by scripts)
├── start-all.sh                # Start all EC2 + configure + deploy everything
├── stop-all.sh                 # Stop all EC2 instances
├── setup-config.sh             # One-time config: inventory, prometheus, dashboard
├── deploy-dashboard.sh         # Standalone dashboard + API redeploy
└── README.md                   # This file
```

---

## Technology Stack

| Component          | Technology                        | Purpose                              |
|--------------------|-----------------------------------|--------------------------------------|
| Cloud              | AWS EC2 (us-east-1)               | Hosts Jenkins, K8s master, workers   |
| Infrastructure     | Terraform 1.6+                    | VPC, EC2, IAM, S3 state              |
| Configuration      | Ansible                           | Node provisioning (Docker, K8s)      |
| CI/CD              | Jenkins                           | Pipeline 1 (deploy) + Pipeline 2 (recovery) |
| Container Registry | DockerHub                         | Image storage & distribution         |
| Orchestration      | Kubernetes 1.29 + Flannel CNI     | Container scheduling & self-healing  |
| Monitoring         | Prometheus + Node Exporter        | CPU, RAM, Disk, Network metrics      |
| Alerting           | Alertmanager                      | Webhook → Jenkins recovery trigger   |
| Dashboard          | HTML/CSS/JS (dark theme) + Flask  | Real-time monitoring UI              |
| App Backend        | Flask (Python)                    | Student Result Portal API            |
| App Frontend       | NGINX (static)                    | Student Result Portal UI             |
| App Database       | MySQL 8.0                         | Persistent storage                   |
| Reverse Proxy      | NGINX                             | Dashboard + API proxy routing        |

---

## Prerequisites

1. **AWS Account** with an EC2 key pair named `infrarevive-key`
2. **DockerHub account** for image pushes
3. **GitHub repository** with webhook access
4. **Local machine** with: Terraform, Ansible, AWS CLI, kubectl, SSH key
5. **S3 bucket** `infrarevive-tfstate` (created automatically by Terraform)

---

## Quick Start

```bash
# 1. Provision AWS infrastructure
cd terraform
terraform init
terraform apply -auto-approve

# 2. Get IPs and configure everything
cd ..
./setup-config.sh

# 3. Configure Kubernetes master + workers with Ansible
ansible-playbook -i ansible/inventory.ini ansible/setup-master.yml
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml

# 4. Deploy the application to Kubernetes
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/persistent-volume.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml

# 5. Start all services (Prometheus, Alertmanager, Dashboard, Dashboard API)
./start-all.sh
```

**Access points after start:**
- Dashboard: `http://<JENKINS_IP>/infrarevive/`
- Jenkins: `http://<JENKINS_IP>:8080`
- Prometheus: `http://<JENKINS_IP>:9090`
- App: `http://<WORKER_IP>:30080`
- API: `http://<WORKER_IP>:30500`

---

## How Recovery Works

When a worker node dies:

1. **Prometheus** detects `up{job="node-exporter"} == 0` for 30 seconds
2. **Alertmanager** fires `NodeDown` alert and sends webhook to Jenkins
3. **Jenkins Pipeline 2** (Recovery) triggers automatically:
   - Identifies which worker is dead (matches private IPs against `kubectl get nodes`)
   - Deletes the ghost node object from Kubernetes
   - `terraform destroy -target=aws_instance.k8s_workers[N]` — destroys dead EC2
   - `terraform apply -target=aws_instance.k8s_workers[N]` — creates fresh EC2
   - Updates Prometheus scrape targets with new IP
   - Waits for SSH on the new instance
   - Regenerates Ansible inventory with new IP
   - Gets fresh `kubeadm token create --print-join-command` from master
   - Runs Ansible `setup-workers.yml --limit <new_ip>` (Docker, containerd, kubeadm, kubelet, kubectl, node-exporter)
   - Verifies node reports `Ready` in Kubernetes
   - Verifies pods are rescheduled and app is running
4. **Total recovery time: under 5 minutes, fully automatic**

---

## Dashboard

The dashboard is a **dark-themed single-page application** with real-time data from:

- **Prometheus API** — CPU, RAM, Disk, Network metrics (range queries for graphs)
- **Kubernetes API** (via dashboard-api) — node details, pod counts, cluster events
- **AWS API** (via dashboard-api) — EC2 instance IDs, states, availability zones
- **Jenkins API** — recovery pipeline build status and history
- **Alertmanager API** — active alerts and severity counts

**Views:**
- **Dashboard** — Cluster status bar, service cards, live metric graphs, alert summary, cluster events, recovery history
- **Cluster Nodes** — Full node table (16 columns: name, role, status, IPs, instance ID, AZ, EC2 state, CPU/RAM/Disk %, pods, versions, uptime)
- **Recovery** — Timeline of recovery pipeline stages with timestamps + full history table
- **Alerts** — Active alerts table with severity, instance, state, and summary

Click any node in the table to see a detailed modal with conditions, pods, capacity, and all metadata.

---

## Documentation

Detailed documentation is in the [`docs/`](docs/) folder:

- [Architecture](docs/ARCHITECTURE.md) — System design and component interactions
- [Deployment Guide](docs/DEPLOYMENT.md) — Step-by-step production deployment
- [Setup Guide](docs/SETUP.md) — Initial environment setup
- [Recovery Flow](docs/RECOVERY-FLOW.md) — Detailed recovery pipeline walkthrough
- [Dashboard Guide](docs/DASHBOARD.md) — Dashboard features and data sources
- [API Documentation](docs/API.md) — All API endpoints (dashboard-api, Flask, proxies)
- [Pipeline Documentation](docs/PIPELINES.md) — Jenkins CI/CD + Recovery pipelines
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Common issues and fixes

---

## Key Design Decisions

1. **No Puppet** — Configuration management uses only Ansible (idempotent playbooks)
2. **No Email Alerts** — Replaced with a real-time monitoring dashboard (no SMTP/Gmail)
3. **Terraform targeted destroy/apply** — Only the dead worker index is touched, never healthy nodes
4. **Private IP matching** — kubelet registers with private IP; recovery pipeline matches on this, not public IP
5. **NGINX reverse proxy** — All API calls are same-origin via nginx, avoiding CORS issues
6. **Dashboard API backend** — Browser can't call AWS (SigV4) or K8s (certs) directly; Flask proxy handles it

---

## Project Scripts

| Script               | Purpose                                              |
|----------------------|------------------------------------------------------|
| `start-all.sh`       | Start EC2 instances, configure, deploy app + dashboard + API |
| `stop-all.sh`        | Stop all EC2 instances (state preserved in S3)       |
| `setup-config.sh`    | One-time: fill inventory, prometheus config, deploy dashboard |
| `deploy-dashboard.sh`| Standalone: redeploy dashboard + API only             |
