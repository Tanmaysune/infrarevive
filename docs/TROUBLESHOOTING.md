# Troubleshooting

Common issues, root causes, and fixes for the INFRAREVIVE system.

---

## Infrastructure (Terraform / AWS)

### Terraform state lock error

**Symptom**: `Error acquiring the state lock` when running `terraform apply` or `terraform destroy`.

**Cause**: A previous Terraform run crashed or was interrupted, leaving a lock in the S3 backend (DynamoDB or S3 lock).

**Fix**:
```bash
cd terraform/
# Force-unlock with the lock ID shown in the error
terraform force-unlock <LOCK_ID>
```
If the issue persists, verify no other Jenkins build is running Terraform concurrently.

---

### Terraform: "Could not identify a dead/missing worker"

**Symptom**: Recovery pipeline fails at Stage 3 (Identify Dead Worker) with:
```
ERROR: Could not identify a dead/missing worker -- all 3 workers show Ready in kubectl.
```

**Cause**: The recovery pipeline was triggered (e.g., by a flapping alert) but all workers are actually healthy. This is a safety mechanism — it prevents destroying a healthy node.

**Fix**:
1. Check if the alert was a false positive: `kubectl get nodes -o wide`
2. If all nodes are Ready, the pipeline correctly aborted — no action needed
3. If a node is actually dead but still shows as Ready in kubectl (stale cache), manually delete it:
   ```bash
   kubectl delete node <node-name>
   ```
   Then re-trigger the recovery pipeline.

---

### EC2 instances get new public IPs after stop/start

**Symptom**: After running `stop-all.sh` then `start-all.sh`, the dashboard or kubectl can't connect.

**Cause**: AWS EC2 instances receive new public IPs when stopped and started (unless using Elastic IPs).

**Fix**: Always use `start-all.sh` — it automatically:
1. Fetches new IPs from AWS
2. Regenerates kubeconfig with new master IP
3. Updates Prometheus scrape targets
4. Rebuilds Ansible inventory
5. Re-syncs everything to Jenkins EC2

If you need stable IPs, attach Elastic IPs in the Terraform config.

---

### S3 backend bucket doesn't exist

**Symptom**: `terraform init` fails with `The specified bucket does not exist`.

**Cause**: The S3 bucket `infrarevive-tfstate` hasn't been created yet (first-time setup).

**Fix**: The Terraform config includes an `aws_s3_bucket.tfstate` resource with `prevent_destroy = true`. Run `terraform apply` once without the backend configured, or manually create the bucket:
```bash
aws s3api create-bucket --bucket infrarevive-tfstate --region us-east-1
```
Then run `terraform init` again.

---

## Kubernetes

### Node shows NotReady after recovery

**Symptom**: New worker node appears in `kubectl get nodes` but shows `NotReady`.

**Cause**: kubelet hasn't fully started or containerd isn't running properly.

**Fix**:
```bash
# SSH to the new worker
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<worker-ip>

# Check kubelet logs
sudo journalctl -u kubelet --no-pager | tail -50

# Restart kubelet
sudo systemctl restart kubelet

# Verify containerd
sudo systemctl status containerd
```

Common sub-causes:
- **Swap not disabled**: `swapoff -a` and remove from `/etc/fstab`
- **containerd misconfigured**: Check `SystemdCgroup = true` in `/etc/containerd/config.toml`
- **kubelet certs missing**: Re-run `kubeadm join` (Ansible handles this automatically)

---

### Flannel pods in CrashLoopBackOff

**Symptom**: `kube-flannel` pods keep crashing on a node.

**Cause**: Flannel CNI misconfiguration or incorrect pod CIDR.

**Fix**:
```bash
# Check flannel logs
kubectl logs -n kube-flannel <flannel-pod> --tail=50

# Verify the pod CIDR matches (should be 10.244.0.0/16)
kubectl get pods -n kube-flannel -o wide

# If needed, re-apply Flannel
kubectl apply -f kubernetes/kube-flannel.yaml
```

---

### Pods stuck in Pending after node recovery

**Symptom**: Application pods remain in `Pending` state after a new node joins.

**Cause**: The scheduler hasn't rescheduled pods, or there are resource constraints.

**Fix**:
```bash
# Check why pods are pending
kubectl describe pod <pod-name> -n infrarevive

# Common causes:
# 1. Node not Ready yet — wait 30-60s
# 2. Insufficient resources — check node capacity
# 3. PVC pending — check persistent volume binding

# Force rescheduling (delete pods so scheduler recreates them)
kubectl delete pods --all -n infrarevive
```

---

### kubeadm token expired

**Symptom**: Recovery pipeline fails at Stage 9 (Get Fresh Join Command) or Stage 10 (Ansible Configure).

**Cause**: The kubeadm join token has expired (tokens are valid for 24 hours by default).

**Fix**: The pipeline automatically generates a fresh token via `kubeadm token create --print-join-command`. If this fails:
```bash
# SSH to master
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<master-ip>

# Create a new token
sudo kubeadm token create --print-join-command

# If the master itself is having issues:
sudo kubeadm token list
sudo kubeadm token create --ttl 2h
```

---

## Monitoring (Prometheus / Alertmanager)

### Prometheus targets all DOWN

**Symptom**: Dashboard shows all nodes as critical, all node-exporter targets show as down.

**Cause**: Prometheus is scraping the wrong IPs (stale config after IP change).

**Fix**:
```bash
# On Jenkins EC2, regenerate Prometheus config
# The start-all.sh script does this automatically
./start-all.sh

# Or manually:
# 1. Get current worker IPs
cd terraform && terraform output -json worker_public_ips | jq -r '.[]'

# 2. Edit /etc/prometheus/prometheus.yml with correct IPs

# 3. Restart Prometheus
sudo systemctl restart prometheus

# 4. Verify targets
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health: .health}'
```

---

### Alertmanager not triggering recovery

**Symptom**: A node is down but the recovery pipeline doesn't trigger.

**Cause**: Alertmanager webhook URL is wrong, Jenkins Generic Webhook Trigger not configured, or token mismatch.

**Fix**:
1. Check Alertmanager config:
   ```bash
   cat /etc/alertmanager/alertmanager.yml
   # Verify URL: http://localhost:8080/generic-webhook-trigger/invoke?token=INFRAREVIVE_RECOVERY_TOKEN
   ```

2. Check Alertmanager is running:
   ```bash
   sudo systemctl status alertmanager
   ```

3. Check Prometheus can reach Alertmanager:
   ```bash
   curl -s localhost:9093/api/v2/status | jq .versionInfo.version
   ```

4. Manually test the webhook:
   ```bash
   curl -X POST "http://localhost:8080/generic-webhook-trigger/invoke?token=INFRAREVIVE_RECOVERY_TOKEN"
   ```

5. Verify the Jenkins job `infrarevive-recovery` exists and is configured with Generic Webhook Trigger.

---

### Prometheus rule evaluation errors

**Symptom**: Prometheus logs show `rule evaluation failed`.

**Cause**: Syntax error in alert rules or missing metrics.

**Fix**:
```bash
# Check Prometheus logs
sudo journalctl -u prometheus --no-pager | grep -i "error"

# Validate alert rules syntax
promtool check rules /etc/prometheus/alert.rules.yml

# Check if node-exporter metrics are available
curl -s 'localhost:9090/api/v1/query?query=up{job="node-exporter"}' | jq .
```

---

## Dashboard

### Dashboard shows blank page

**Symptom**: Navigating to `http://<JENKINS_IP>/infrarevive/` shows a blank or error page.

**Cause**: NGINX not running, dashboard files not deployed, or file permissions.

**Fix**:
```bash
# Check NGINX
sudo systemctl status nginx
sudo nginx -t

# Check dashboard files exist
ls -la /var/www/infrarevive/

# Check NGINX config
cat /etc/nginx/conf.d/infrarevive-nginx.conf

# Restart NGINX
sudo systemctl restart nginx

# Re-deploy dashboard
./deploy-dashboard.sh
```

---

### Dashboard API returns 500 errors

**Symptom**: Dashboard loads but node table, AWS instances, or service status cards show errors.

**Cause**: Dashboard API (Flask on port 5001) can't run kubectl or aws CLI.

**Fix**:
```bash
# Check if dashboard-api is running
sudo systemctl status dashboard-api

# Check logs
sudo journalctl -u dashboard-api --no-pager | tail -30

# Verify kubectl works as ec2-user
sudo -u ec2-user KUBECONFIG=/home/ec2-user/.kube/config kubectl get nodes

# Verify aws CLI works
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text

# Verify kubeconfig permissions
ls -la /home/ec2-user/.kube/config
# Should be readable by ec2-user

# Restart dashboard-api
sudo systemctl restart dashboard-api
```

---

### Dashboard shows "No Active Recovery" but a recovery is running

**Symptom**: Recovery pipeline is running in Jenkins but dashboard doesn't show it as active.

**Cause**: Dashboard checks Jenkins API for the last build result. If the build is still running, Jenkins returns `null` for the result field — the dashboard should interpret this as "in progress."

**Fix**:
1. Check the Jenkins job name matches what the dashboard queries (`infrarevive-recovery`)
2. Verify Jenkins API is accessible:
   ```bash
   curl -s "http://localhost:8080/job/infrarevive-recovery/lastBuild/api/json" | jq .
   ```
3. Check the dashboard-api `/api/recovery/history` endpoint:
   ```bash
   curl -s localhost:5001/api/recovery/history | jq .
   ```

---

## Ansible

### Ansible: "UNREACHABLE" for worker nodes

**Symptom**: `ansible-playbook` fails with `UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh"}`.

**Cause**: SSH key not found, wrong IP in inventory, or EC2 instance not booted yet.

**Fix**:
1. Verify the SSH key exists on Jenkins EC2:
   ```bash
   ls -la /var/lib/jenkins/.ssh/infrarevive-key.pem
   chmod 600 /var/lib/jenkins/.ssh/infrarevive-key.pem
   ```

2. Test SSH manually:
   ```bash
   ssh -i /var/lib/jenkins/.ssh/infrarevive-key.pem ec2-user@<worker-ip>
   ```

3. Verify inventory IPs are current:
   ```bash
   cat ansible/inventory.ini
   # Compare with: terraform output -json worker_public_ips | jq -r '.[]'
   ```

---

### Ansible re-configures healthy workers (knocking them offline)

**Symptom**: After recovery, other healthy workers go NotReady.

**Cause**: Ansible playbook was run without `--limit` — it re-ran `yum update` and restarted Docker/containerd/kubelet on all workers.

**Fix**: This was a historical bug, now fixed. The recovery pipeline uses `--limit ${NEW_WORKER_IP}` to target only the new node. If you run Ansible manually, always use `--limit`:
```bash
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml \
    --limit <new-worker-ip> --private-key=~/.ssh/infrarevive-key.pem
```

---

### kubeadm join fails with "preflight checks"

**Symptom**: Ansible task "Join worker to Kubernetes cluster" fails with preflight errors.

**Cause**: Stale Kubernetes files from a previous join attempt, or swap still enabled.

**Fix**: The Ansible playbook already adds `--ignore-preflight-errors=all` to the join command. If it still fails:
```bash
# SSH to the worker
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<worker-ip>

# Clean up stale Kubernetes state
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes/kubelet.conf /etc/kubernetes/pki/ca.crt

# Disable swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Re-run the join command manually
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash> --ignore-preflight-errors=all
```

---

## Jenkins

### Jenkins can't connect to Kubernetes

**Symptom**: CI/CD pipeline fails at "Deploy to Kubernetes" stage with `The connection to the server <ip>:6443 was refused`.

**Cause**: kubeconfig on Jenkins EC2 has stale master IP or expired certs.

**Fix**:
```bash
# On Jenkins EC2, check kubeconfig
export KUBECONFIG=/var/lib/jenkins/.kube/config
kubectl get nodes

# If it fails, regenerate kubeconfig from master:
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<master-ip> \
    'sudo cat /etc/kubernetes/admin.conf' > /var/lib/jenkins/.kube/config

# Or run start-all.sh which handles this automatically
```

---

### Jenkins build queue stuck

**Symptom**: Recovery pipeline build is queued but never starts.

**Cause**: `disableConcurrentBuilds()` is set, and a previous build is stuck or hanging.

**Fix**:
1. Check running builds in Jenkins UI: `http://<JENKINS_IP>:8080/job/infrarevive-recovery/`
2. If a build is stuck, click the X to abort it
3. Or from CLI:
   ```bash
   # Get the build number
   curl -s "http://localhost:8080/job/infrarevive-recovery/lastBuild/api/json" | jq .number

   # Stop the build (requires Jenkins CLI or UI)
   ```

---

### Docker build fails in CI/CD

**Symptom**: Pipeline 1 fails at "Build Docker Images" stage.

**Cause**: Docker daemon not running, or Dockerfile syntax error.

**Fix**:
```bash
# Check Docker on Jenkins EC2
sudo systemctl status docker
sudo systemctl start docker

# Verify jenkins user can use Docker
sudo -u jenkins docker ps

# If permission denied:
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

---

## Quick Diagnostic Commands

```bash
# Check all EC2 instances
aws ec2 describe-instances --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress,PrivateIpAddress]' --output table

# Check Kubernetes cluster health
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get cs

# Check monitoring services
sudo systemctl status prometheus alertmanager nginx dashboard-api

# Check Prometheus targets
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health: .health}'

# Check Alertmanager alerts
curl -s localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, state: .status.state}'

# Check Jenkins jobs
curl -s "http://localhost:8080/api/json?tree=jobs[name]" | jq .

# Check dashboard API health
curl -s localhost:5001/health | jq .
```
