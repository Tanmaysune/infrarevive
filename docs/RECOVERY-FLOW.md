# Recovery Flow

This document details the exact step-by-step process when a worker node fails.

## Trigger Chain

```
Worker EC2 dies (hardware/AWS/OOM)
       │
       ▼
Node Exporter (port 9100) stops responding
       │
       ▼
Prometheus scrape fails → up{job="node-exporter"} == 0
       │
       ▼ (30s `for` duration)
Alertmanager fires NodeDown alert (severity: critical)
       │
       ▼
Alertmanager sends webhook to:
  http://localhost:8080/generic-webhook-trigger/invoke?token=INFRAREVIVE_RECOVERY_TOKEN
       │
       ▼
Jenkins Pipeline 2 (infrarevive-recovery) triggers automatically
```

## Pipeline 2 Stages (Jenkinsfile-Recovery)

### Stage 1: Identify Failed Node
- Runs `kubectl get nodes -o wide` to show current cluster state
- Lists dead nodes (NotReady/Unknown) or confirms EC2 is dead entirely

### Stage 2: Terraform Init
- `terraform init -reconfigure` — connects to S3 backend state

### Stage 3: Identify Dead Worker
- Fetches worker public IPs from `terraform output`
- Fetches worker **private** IPs from `terraform output` (critical: kubelet registers with private IP)
- For each worker, checks `kubectl get nodes -o wide | awk -v ip="$privateIp" '$6==ip {print $2}'`
- If status is "NotReady" → deletes ghost node object from Kubernetes
- If status is empty (NotFound) → EC2 itself is dead
- Sets `env.DEAD_WORKER_INDEX` to the dead worker's index (0, 1, or 2)
- **Fails loud** if no dead worker found (prevents destroying healthy nodes)

### Stage 4: Terraform Destroy Dead Node
```bash
terraform destroy -target='aws_instance.k8s_workers[INDEX]' -auto-approve
```
Only the dead worker index is destroyed. Other workers and master are untouched.

### Stage 5: Terraform Provision New Node
```bash
terraform apply -target='aws_instance.k8s_workers[INDEX]' -auto-approve
```
Creates a fresh EC2 instance with the same configuration.

### Stage 6: Update Monitoring Targets
- Regenerates `prometheus.yml` with new worker IPs
- Copies to Jenkins EC2 and restarts Prometheus

### Stage 7: Wait for Node Boot
- `sleep 90` for EC2 to boot
- SSH retry loop (5 attempts, 20s apart) to confirm the new node is reachable

### Stage 8: Auto-Update Ansible Inventory
- Fetches all current worker IPs from Terraform
- Rewrites `ansible/inventory.ini` with fresh IPs (all 3 workers)

### Stage 9: Get Fresh Join Command
- SSHes to master and runs `kubeadm token create --print-join-command`
- Saves the join command to `/tmp/kubeadm_join_command.sh`

### Stage 10: Ansible Configure New Node
```bash
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml \
    --limit NEW_WORKER_IP --private-key=SSH_KEY -v
```
**Critical**: `--limit` ensures only the new node is configured. Without it, Ansible would re-run yum update + restart services on healthy workers too.

Ansible installs:
- Docker + containerd (with SystemdCgroup=true)
- kubeadm, kubelet, kubectl (v1.29)
- Kernel modules (overlay, br_netfilter)
- sysctl (bridge-nf-call-iptables, ip_forward)
- Swap disabled
- Node Exporter
- Executes kubeadm join

### Stage 11: Verify Node Joined Cluster
- `sleep 30` for kubelet to register
- `kubectl wait --for=condition=Ready node --all --timeout=120s`

### Stage 12: Verify Pods Rescheduled
- `kubectl get pods -n infrarevive -o wide`
- `kubectl wait --for=condition=Ready pod --all -n infrarevive --timeout=120s`

## Post-Recovery

- Pipeline logs total duration (target: < 5 minutes)
- Dashboard shows node as Ready with fresh metrics
- Pods automatically rescheduled by Kubernetes scheduler
- MySQL data preserved (PV with Retain policy + nodeAffinity)

## Why Private IP Matching?

kubelet registers its node with the **private IP** as INTERNAL-IP (no cloud-controller-manager is installed, so EXTERNAL-IP is always `<none>`). The recovery pipeline matches Terraform private IPs against `kubectl get nodes -o wide` column 6. Matching on public IP would never succeed and silently fall back to guessing a worker index — which could destroy a healthy node.
