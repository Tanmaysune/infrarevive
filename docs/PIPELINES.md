# Pipeline Documentation

INFRAREVIVE runs two Jenkins pipelines. Pipeline 1 handles CI/CD (build, push, deploy). Pipeline 2 handles automatic node recovery. Both run on the Jenkins EC2 instance.

---

## Pipeline 1 — CI/CD (`Jenkinsfile-CICD`)

**Jenkins Job Name**: `infrarevive-cicd`

**Trigger**: GitHub webhook on push to `main` branch.

**Purpose**: Build Docker images for the Flask API and frontend, push them to DockerHub, then deploy to the Kubernetes cluster with a rolling update and automatic rollback on failure.

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `DOCKERHUB_USERNAME` | `sune21tanmay` | DockerHub account |
| `IMAGE_API` | `<user>/infrarevive-api` | API image name |
| `IMAGE_FRONT` | `<user>/infrarevive-frontend` | Frontend image name |
| `TAG` | `${BUILD_NUMBER}` | Unique tag per build |
| `NAMESPACE` | `infrarevive` | Kubernetes namespace |
| `KUBECONFIG_PATH` | `/var/lib/jenkins/.kube/config` | kubeconfig on Jenkins EC2 |

### Stages

```
Checkout Code → Build Docker Images → Push to DockerHub → Deploy to Kubernetes
```

#### Stage 1: Checkout Code
- Clones the GitHub repository (`main` branch)
- Logs the build number

#### Stage 2: Build Docker Images
- Builds `infrarevive-api` from `./app/Dockerfile`
- Builds `infrarevive-frontend` from `./frontend/Dockerfile`
- Tags each image with both `${BUILD_NUMBER}` and `latest`

```bash
docker build -t ${IMAGE_API}:${TAG} -t ${IMAGE_API}:latest ./app
docker build -t ${IMAGE_FRONT}:${TAG} -t ${IMAGE_FRONT}:latest ./frontend
```

#### Stage 3: Push Images to Docker Hub
- Uses Jenkins credentials `dockerhub-credentials` (username/password)
- Pushes all 4 image tags (api:tag, api:latest, frontend:tag, frontend:latest)

```bash
echo ${DOCKER_PASS} | docker login -u ${DOCKER_USER} --password-stdin
docker push ${IMAGE_API}:${TAG}
docker push ${IMAGE_API}:latest
docker push ${IMAGE_FRONT}:${TAG}
docker push ${IMAGE_FRONT}:latest
```

#### Stage 4: Deploy to Kubernetes
- Applies all manifests idempotently (`kubectl apply`):
  - `namespace.yaml` → `configmap.yaml` → `secret.yaml` → `persistent-volume.yaml`
  - `deployment.yaml` → `service.yaml` → `ingress.yaml`
- Triggers a rolling update by setting the new image tag:

```bash
kubectl set image deployment/flask-api flask-api=${IMAGE_API}:${TAG} -n infrarevive
kubectl set image deployment/frontend frontend=${IMAGE_FRONT}:${TAG} -n infrarevive
```

- Waits for rollout to complete (120s timeout per deployment):

```bash
kubectl rollout status deployment/flask-api -n infrarevive --timeout=120s
kubectl rollout status deployment/frontend -n infrarevive --timeout=120s
```

- Prints final pod and service status

### Post-Build Actions

| Condition | Action |
|-----------|--------|
| **Success** | Logs deployment confirmation |
| **Failure** | `kubectl rollout undo` on both deployments (reverts to previous version) |
| **Always** | Removes local Docker images to free disk space |

```bash
# Failure rollback
kubectl rollout undo deployment/flask-api -n infrarevive || true
kubectl rollout undo deployment/frontend -n infrarevive || true
```

### Required Jenkins Credentials

| Credential ID | Type | Purpose |
|---------------|------|---------|
| `dockerhub-credentials` | Username/Password | DockerHub login for image push |

### Required Jenkins Plugins

- Pipeline
- Git
- Docker
- Kubernetes CLI (kubectl)

---

## Pipeline 2 — Recovery (`Jenkinsfile-Recovery`)

**Jenkins Job Name**: `infrarevive-recovery`

**Trigger**: Alertmanager webhook → Jenkins Generic Webhook Trigger (token: `INFRAREVIVE_RECOVERY_TOKEN`).

**Purpose**: Automatically detect a dead worker node, destroy it via Terraform, provision a replacement, configure it with Ansible, and rejoin it to the Kubernetes cluster — all without human intervention. Target recovery time: under 5 minutes.

**Concurrency**: `disableConcurrentBuilds()` — prevents overlapping recovery runs.

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `KUBECONFIG_PATH` | `/var/lib/jenkins/.kube/config` | kubeconfig on Jenkins EC2 |
| `NAMESPACE` | `infrarevive` | Kubernetes namespace |
| `TERRAFORM_DIR` | `${WORKSPACE}/terraform` | Terraform working directory |
| `SSH_KEY` | `/var/lib/jenkins/.ssh/infrarevive-key.pem` | EC2 SSH key for Ansible |

### Helper Functions

#### `getValidWorkerIps()`
- Fetches worker **public** IPs from `terraform output -json worker_public_ips`
- Retries up to 10 times (10s apart) until all 3 IPs are non-empty
- Used for: SSH access, Ansible inventory, Prometheus targets

#### `getValidWorkerPrivateIps()`
- Fetches worker **private** IPs from `terraform output -json worker_private_ips`
- Same retry logic
- Used for: matching against `kubectl get nodes -o wide` (kubelet registers with private IP)
- Index-aligned with `getValidWorkerIps()` (same resource, same ordering)

### Stages

```
Identify Failed Node → Terraform Init → Identify Dead Worker → Terraform Destroy
→ Terraform Provision → Update Monitoring → Wait for Boot → Update Inventory
→ Get Join Command → Ansible Configure → Verify Node Ready → Verify Pods
```

#### Stage 1: Identify Failed Node
- Prints current cluster state: `kubectl get nodes -o wide`, `kubectl get pods -n infrarevive -o wide`
- Lists dead nodes: `kubectl get nodes | grep -E "NotReady|Unknown"`

#### Stage 2: Terraform Init
- `terraform init -reconfigure` — connects to S3 backend (`infrarevive-tfstate`)

#### Stage 3: Identify Dead Worker
This is the most critical stage — it determines which worker to destroy.

1. Fetches worker public IPs and private IPs from Terraform output
2. For each worker (index 0, 1, 2):
   - Extracts the node status by matching private IP against `kubectl get nodes -o wide` column 6 (INTERNAL-IP):

   ```bash
   kubectl get nodes -o wide --no-headers | awk -v ip="${privateIp}" '$6==ip {print $2}'
   ```

   - If status is **NotReady** → deletes the ghost node object from Kubernetes:

   ```bash
   kubectl delete node ${deadNodeName} || true
   ```

   - If status is empty (**NotFound**) → the EC2 instance itself is dead
   - Sets `env.DEAD_WORKER_INDEX` and breaks

3. **Safety check**: If no dead worker found (all 3 show Ready), the pipeline **fails loud** to prevent destroying a healthy node:

   ```
   error("Could not identify a dead/missing worker -- all 3 workers show Ready in kubectl. Aborting to avoid destroying a healthy node.")
   ```

#### Stage 4: Terraform Destroy Dead Node
- Destroys ONLY the dead worker index — other workers, master, and Jenkins are untouched:

```bash
terraform destroy -target='aws_instance.k8s_workers[${DEAD_WORKER_INDEX}]' -auto-approve
```

#### Stage 5: Terraform Provision New Node
- Creates a fresh EC2 instance at the same index:

```bash
terraform apply -target='aws_instance.k8s_workers[${DEAD_WORKER_INDEX}]' -auto-approve
```

- Fetches the new worker's public IP, master IP, and Jenkins IP from Terraform outputs
- Sets `env.NEW_WORKER_IP`, `env.MASTER_IP`, `env.JENKINS_IP`

#### Stage 6: Update Monitoring Targets
- Regenerates `/etc/prometheus/prometheus.yml` with all current node IPs (master + 3 workers) as node-exporter targets
- Copies to Jenkins EC2 and restarts Prometheus:

```bash
sudo cp /tmp/prometheus-recovery.yml /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus
```

#### Stage 7: Wait for Node Boot
- `sleep 90` — waits for EC2 to fully boot
- SSH retry loop (5 attempts, 20s apart) to confirm the new node is reachable:

```bash
for i in 1 2 3 4 5; do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -i ${SSH_KEY} ec2-user@${NEW_WORKER_IP} 'echo SSH_OK' && break || sleep 20
done
```

#### Stage 8: Auto-Update Ansible Inventory
- Fetches all current worker IPs from Terraform
- Rewrites `ansible/inventory.ini` with fresh IPs for all 3 workers + master + Jenkins

#### Stage 9: Get Fresh Join Command
- SSHes to master and generates a new kubeadm token:

```bash
ssh -i ${SSH_KEY} ec2-user@${MASTER_IP} 'kubeadm token create --print-join-command' > /tmp/kubeadm_join_command.sh
```

#### Stage 10: Ansible Configure New Node
**Critical**: Uses `--limit ${NEW_WORKER_IP}` to configure ONLY the new node. Without `--limit`, Ansible would re-run `yum update` and restart Docker/containerd/kubelet on the two healthy workers — potentially knocking them offline.

```bash
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml \
    --limit ${NEW_WORKER_IP} --private-key=${SSH_KEY} -v
```

Ansible installs on the new node:
- System update + iproute-tc
- Swap disabled (permanent via fstab edit)
- Kernel modules: overlay, br_netfilter
- sysctl: bridge-nf-call-iptables, ip_forward
- Docker + containerd (SystemdCgroup=true)
- kubeadm, kubelet, kubectl (v1.29)
- Node Exporter (v1.7.0) as systemd service
- Executes `kubeadm join` (with `--ignore-preflight-errors=all`)

The `kubeadm join` task uses `creates: /etc/kubernetes/kubelet.conf` guard for idempotency.

#### Stage 11: Verify Node Joined Cluster
- `sleep 30` — waits for kubelet to register with API server
- `kubectl wait --for=condition=Ready node --all --timeout=120s`
- Prints final node status

#### Stage 12: Verify Pods Rescheduled and App Running
- `kubectl get pods -n infrarevive -o wide`
- `kubectl wait --for=condition=Ready pod --all -n infrarevive --timeout=120s`
- Prints final pod and service status

### Post-Build Actions

| Condition | Output |
|-----------|--------|
| **Success** | "RECOVERY COMPLETE — Dead node replaced. Cluster healthy. App running. MySQL data intact." |
| **Failure** | "RECOVERY FAILED — Manual check needed" with common causes: SSH key missing, Terraform state mismatch, Kubeadm token expired |

### Required Jenkins Plugins

- Pipeline
- Git
- Generic Webhook Trigger
- Docker (not strictly required for recovery, but installed)
- SSH Agent (for key-based SSH)

### Generic Webhook Trigger Configuration

| Setting | Value |
|---------|-------|
| Token | `INFRAREVIVE_RECOVERY_TOKEN` |
| Variable | (none — the pipeline detects the dead node itself) |
| Print post content | No |
| Cause | `Recovery triggered by Alertmanager` |

### Alertmanager Webhook Config

```yaml
# prometheus/alertmanager.yml
route:
  receiver: 'jenkins-webhook'
  routes:
    - match:
        severity: critical
      receiver: 'jenkins-webhook'
    - match:
        severity: warning
      receiver: 'jenkins-webhook'

receivers:
  - name: 'jenkins-webhook'
    webhook_configs:
      - url: 'http://localhost:8080/generic-webhook-trigger/invoke?token=INFRAREVIVE_RECOVERY_TOKEN'
        send_resolved: true
```

---

## Trigger Flow Summary

```
┌─────────────────────────────────────────────────────┐
│ PIPELINE 1 (CI/CD)                                  │
│                                                     │
│  Git Push (main)                                    │
│       │                                             │
│       ▼                                             │
│  GitHub Webhook → Jenkins                           │
│       │                                             │
│       ▼                                             │
│  Build → Push → kubectl apply → Rolling Update      │
│       │                                             │
│       ├── success → New version live                │
│       └── failure → kubectl rollout undo            │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ PIPELINE 2 (Recovery)                               │
│                                                     │
│  Worker EC2 dies                                    │
│       │                                             │
│       ▼                                             │
│  Node Exporter unreachable → Prometheus up==0       │
│       │                                             │
│       ▼  (30s for)                                  │
│  Alertmanager fires NodeDown (critical)             │
│       │                                             │
│       ▼                                             │
│  Webhook → Jenkins Generic Webhook Trigger          │
│       │                                             │
│       ▼                                             │
│  Identify Dead → Destroy → Provision → Configure    │
│       │                                             │
│       ▼                                             │
│  New node Ready → Pods rescheduled → Cluster healed │
└─────────────────────────────────────────────────────┘
```
