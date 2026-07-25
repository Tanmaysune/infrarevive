# Deployment Guide

## Phase 1: AWS Infrastructure (Terraform)

```bash
cd terraform/

# Initialize with S3 backend
terraform init

# Review the plan
terraform plan

# Provision: VPC, subnet, IGW, route tables, security groups, IAM, EC2
terraform apply -auto-approve
```

**Outputs**: Jenkins IP, Master IP, Worker IPs (public + private), instance IDs.

## Phase 2: Configure IPs & Inventory

```bash
cd ..
./setup-config.sh
```
This auto-fills:
- `.env` — all EC2 public IPs
- `ansible/inventory.ini` — real IPs for jenkins, k8s_master, k8s_workers groups
- `prometheus/prometheus.yml` — node-exporter scrape targets
- Deploys dashboard + dashboard-api to Jenkins EC2

## Phase 3: Kubernetes Cluster Setup (Ansible)

```bash
# Configure master node (kubeadm init, Flannel, node-exporter)
ansible-playbook -i ansible/inventory.ini ansible/setup-master.yml

# Configure worker nodes (Docker, kubeadm join, node-exporter)
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml
```

**Note**: The join command is fetched from master and distributed to workers automatically.

## Phase 4: Deploy Application to Kubernetes

```bash
export KUBECONFIG=~/.kube/config

kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/persistent-volume.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml

# Initialize database with sample data
kubectl exec -n infrarevive deploy/flask-api -- curl -s localhost:5000/init-db
```

## Phase 5: Monitoring & Dashboard

```bash
# Start everything (EC2 + Prometheus + Alertmanager + NGINX + Dashboard + Dashboard API)
./start-all.sh
```

This script:
1. Starts all EC2 instances
2. Fetches new IPs (EC2 gets new public IPs on stop/start)
3. Regenerates API server certs for new master IP
4. Syncs kubeconfig to Jenkins EC2
5. Cleans ghost nodes + ensures Flannel is healthy
6. Restarts Prometheus + Alertmanager
7. Deploys dashboard + dashboard API + nginx reverse proxy
8. Waits for app pods to be Ready

## Phase 6: Jenkins Configuration

On Jenkins EC2 (`http://<JENKINS_IP>:8080`):

1. **Install plugins**: Pipeline, Git, Docker, Kubernetes CLI, Generic Webhook Trigger
2. **Add credentials**:
   - `dockerhub-credentials` — DockerHub username/password
3. **Create Pipeline 1** (`infrarevive-cicd`):
   - Definition: Pipeline script from SCM
   - Repository: your GitHub repo
   - Script path: `Jenkinsfile-CICD`
   - Build trigger: GitHub hook trigger
4. **Create Pipeline 2** (`infrarevive-recovery`):
   - Definition: Pipeline script from SCM
   - Script path: `Jenkinsfile-Recovery`
   - Build trigger: Generic Webhook Trigger (token: `INFRAREVIVE_RECOVERY_TOKEN`)
5. **GitHub Webhook**: point to `http://<JENKINS_IP>:8080/github-webhook/`

## Phase 7: Verify Recovery

```bash
# Simulate a worker failure by stopping a worker EC2
aws ec2 stop-instances --instance-ids <worker-id>

# Watch the dashboard — within 30s Prometheus detects, within 5min recovery completes
# Or watch Jenkins: http://<JENKINS_IP>:8080/job/infrarevive-recovery/
```

## Day-to-Day Operations

| Action | Command |
|--------|---------|
| Stop everything | `./stop-all.sh` |
| Start everything | `./start-all.sh` |
| Redeploy dashboard only | `./deploy-dashboard.sh` |
| Check cluster | `kubectl get nodes -o wide` |
| Check pods | `kubectl get pods -n infrarevive -o wide` |
| Trigger CI/CD | Push to GitHub `main` branch |
