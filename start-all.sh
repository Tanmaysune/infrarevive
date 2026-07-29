#!/bin/bash
set -eu

export AWS_PAGER=""

echo "=== STARTING ALL INFRAREVIVE RESOURCES ==="

# Instance IDs sourced from Terraform state, NOT from AWS tag-based lookups.
# Tags accumulate stale/duplicate matches across destroy+recreate cycles
# (recovery pipeline, taints, etc.) since terminated instances stay visible
# in the AWS API for up to an hour. Terraform state only ever tracks the
# current real resource behind each address -- this eliminates that whole
# class of bug permanently instead of just filtering around it.
cd ~/project/infrarevive/terraform
JENKINS_ID=$(terraform output -raw jenkins_instance_id)
MASTER_ID=$(terraform output -raw master_instance_id)
WORKER_IDS=$(terraform output -json worker_instance_ids | jq -r '.[]' | tr '\n' ' ')
cd ~/project/infrarevive

# Ensure all instances are fully stopped before starting
echo ""
echo "--- Ensuring all instances are fully stopped before starting ---"
for id in $JENKINS_ID $MASTER_ID $WORKER_IDS; do
  STATE=$(aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].State.Name' --output text)
  if [ "$STATE" == "stopping" ]; then
    echo "$id is still stopping, waiting..."
    aws ec2 wait instance-stopped --instance-ids $id
  fi
done

echo "Jenkins  ID : $JENKINS_ID"
echo "Master   ID : $MASTER_ID"
echo "Workers  IDs: $WORKER_IDS"

aws ec2 start-instances --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS --output text

echo ""
echo "Waiting for instances to reach running state..."
aws ec2 wait instance-running --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS
echo "All instances are running."

echo ""
echo "--- Syncing Terraform state with live AWS values ---"
cd ~/project/infrarevive/terraform
terraform apply -refresh-only -auto-approve
cd ~/project/infrarevive

echo ""
echo "--- Fetching new IPs ---"
# Always resolve by instance ID (--instance-ids), never by tag -- an
# instance ID can only ever refer to exactly one real instance, so this
# is unambiguous even if old terminated instances share the same Name tag.
JENKINS_IP=$(aws ec2 describe-instances --instance-ids $JENKINS_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MASTER_IP=$(aws ec2 describe-instances --instance-ids $MASTER_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

WORKER_ID_ARRAY=($WORKER_IDS)
WORKER0_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[0]} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
WORKER1_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[1]} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
WORKER2_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[2]} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ "$WORKER0_IP" == "None" ] || [ "$WORKER1_IP" == "None" ] || [ "$WORKER2_IP" == "None" ]; then
  echo ""
  echo "--- Missing worker IP detected, re-applying Terraform ---"
  (cd ~/project/infrarevive/terraform && terraform apply -auto-approve)
  WORKER0_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[0]} --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  WORKER1_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[1]} --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  WORKER2_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[2]} --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  echo "Corrected Worker IPs: $WORKER0_IP $WORKER1_IP $WORKER2_IP"
fi

echo "Jenkins  : $JENKINS_IP"
echo "Master   : $MASTER_IP"
echo "Worker 0 : $WORKER0_IP"
echo "Worker 1 : $WORKER1_IP"
echo "Worker 2 : $WORKER2_IP"

# Private IPs -- stable across stop/start, used for Prometheus scrape
# targets so alerts (and the recovery pipeline) don't silently break
# every time public IPs change.
MASTER_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $MASTER_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
WORKER0_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[0]} --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
WORKER1_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[1]} --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
WORKER2_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids ${WORKER_ID_ARRAY[2]} --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat > ~/project/infrarevive/.env << EOF
JENKINS_IP=$JENKINS_IP
MASTER_IP=$MASTER_IP
WORKER0_IP=$WORKER0_IP
WORKER1_IP=$WORKER1_IP
WORKER2_IP=$WORKER2_IP
EOF

echo ""
echo "--- Updating inventory.ini ---"
cat > ~/project/infrarevive/ansible/inventory.ini << INV
[jenkins]
$JENKINS_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem

[k8s_master]
$MASTER_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem

[k8s_workers]
$WORKER0_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
$WORKER1_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
$WORKER2_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
INV
echo "inventory.ini updated."

echo ""
echo "--- Updating prometheus.yml ---"
cat > ~/project/infrarevive/prometheus/prometheus.yml << PROM
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files:
  - "alert.rules.yml"
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 'localhost:9093'
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'node-exporter'
    static_configs:
      - targets:
          - '$MASTER_PRIVATE_IP:9100'
          - '$WORKER0_PRIVATE_IP:9100'
          - '$WORKER1_PRIVATE_IP:9100'
          - '$WORKER2_PRIVATE_IP:9100'
  - job_name: 'flask-api'
    metrics_path: '/metrics'
    static_configs:
      - targets: ['$WORKER0_PRIVATE_IP:30500']
PROM
echo "prometheus.yml updated."



# -------------------------------------------------------
# WAIT FOR SSH
# -------------------------------------------------------
wait_for_ssh() {
  local ip=$1
  local label=$2
  echo "Waiting for SSH on $label ($ip)..."
  for i in $(seq 1 40); do
    if ssh -i ~/.ssh/infrarevive-key.pem \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           ec2-user@$ip "echo ok" 2>/dev/null | grep -q ok; then
      echo "$label SSH ready."
      return 0
    fi
    sleep 5
  done
  echo "ERROR: $label SSH not ready after 200s."
  return 1
}

wait_for_ssh $MASTER_IP "Master"
wait_for_ssh $JENKINS_IP "Jenkins"

# -------------------------------------------------------
# REGENERATE API SERVER CERTIFICATE FOR NEW PUBLIC IP
# -------------------------------------------------------
fix_master_cert() {
  echo ""
  echo "--- Regenerating Kubernetes API server certificate for new IP ---"

  ssh -i ~/.ssh/infrarevive-key.pem \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      ec2-user@$MASTER_IP bash -s <<EOF
set -e

NEW_IP="$MASTER_IP"
PRIVATE_IP=\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Detected public IP: \$NEW_IP"
echo "Detected private IP: \$PRIVATE_IP"

sudo rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key

sudo kubeadm init phase certs apiserver \
  --apiserver-cert-extra-sans="\$NEW_IP,\$PRIVATE_IP,127.0.0.1,10.96.0.1"

sudo crictl rm -f \$(sudo crictl ps -q --name kube-apiserver) 2>/dev/null || \
  (sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ && sleep 5 && sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/)

echo "Waiting for API server to become healthy..."
for i in \$(seq 1 30); do
  if curl -sk https://127.0.0.1:6443/healthz | grep -q ok; then
    echo "API server healthy."
    break
  fi
  sleep 5
done
EOF
}

fix_master_cert

echo ""
echo "--- Updating kubeconfig ---"
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@$MASTER_IP:/home/ec2-user/.kube/config \
    ~/.kube/config
sed -i "s|server: https://.*:6443|server: https://$MASTER_IP:6443|" ~/.kube/config
echo "kubeconfig updated."

echo ""
echo "--- Syncing kubeconfig to Jenkins EC2 ---"
scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ~/.kube/config \
  ec2-user@$JENKINS_IP:/tmp/config
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
  "sudo mkdir -p /var/lib/jenkins/.kube && \
   sudo cp /tmp/config /var/lib/jenkins/.kube/config && \
   sudo chown jenkins:jenkins /var/lib/jenkins/.kube/config"
echo "Jenkins kubeconfig synced."

# -------------------------------------------------------
# ENSURE FLANNEL CNI IS HEALTHY (root cause of stuck
# ContainerCreating / Init:CrashLoopBackOff after stop/start)
# -------------------------------------------------------
echo ""
echo ""
echo "--- Cleaning up ghost/stale nodes ---"
kubectl get nodes --no-headers 2>/dev/null | awk '$2=="NotReady"{print $1}' | xargs -r -I{} kubectl delete node {} || true

# -------------------------------------------------------
# SELF-HEAL: JOIN ANY WORKER THAT ISN'T ACTUALLY IN THE
# CLUSTER YET. Covers every way a worker can end up as a
# healthy EC2 instance that was never kubeadm-joined:
# partial recovery-pipeline failures, manual taints,
# instances swapped outside the normal flow, etc. Safe to
# run every single start -- already-joined workers are
# detected and skipped, nothing is touched on them.
# -------------------------------------------------------
echo ""
echo "--- Checking all workers are actually joined to the cluster ---"

CURRENT_NODE_IPS=$(kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print $6}')

for idx in 0 1 2; do
  eval WPUB=\$WORKER${idx}_IP
  WPRIV=$(cd terraform && terraform output -json worker_private_ips | jq -r ".[$idx]")

  if echo "$CURRENT_NODE_IPS" | grep -q "^${WPRIV}$"; then
    echo "Worker $idx ($WPRIV / $WPUB) already joined -- skipping."
    continue
  fi

  echo "Worker $idx ($WPRIV / $WPUB) is NOT in the cluster -- joining now..."

  # sshd/cloud-init on a freshly-booted instance can still be initializing
  # even though EC2 already reports "running" -- ansible-playbook with no
  # wait here is what caused "Connection closed by remote host" / UNREACHABLE
  # against a worker that just started. Wait for real SSH readiness first.
  if ! wait_for_ssh "$WPUB" "Worker $idx" 2>/dev/null; then
    echo "WARNING: worker $idx ($WPUB) never became SSH-reachable -- skipping, fix manually."
    continue
  fi

  # Fresh join token/command from master (old ones expire after 24h)
  ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$MASTER_IP \
    "kubeadm token create --print-join-command" > /tmp/kubeadm_join_command.sh

  if [ ! -s /tmp/kubeadm_join_command.sh ]; then
    echo "WARNING: could not fetch a join command from master -- skipping worker $idx, fix manually."
    continue
  fi

  # Retry the playbook itself -- even after SSH is "ready" per wait_for_ssh,
  # the very first real ansible connection can still hit a closing window.
  JOIN_OK=0
  for attempt in 1 2 3; do
    if ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml --limit "$WPUB"; then
      JOIN_OK=1
      break
    fi
    echo "Ansible run failed for worker $idx ($WPUB), attempt $attempt/3 -- retrying in 15s..."
    sleep 15
  done
  if [ "$JOIN_OK" -ne 1 ]; then
    echo "WARNING: Ansible run failed for worker $idx ($WPUB) after 3 attempts -- check manually, continuing with the rest."
  fi
done

echo "--- Ensuring flannel CNI is healthy ---"

FLANNEL_MANIFEST=~/project/infrarevive/kubernetes/kube-flannel.yaml

# Pin a local copy so the manifest never drifts from the image tag again.
# If it doesn't exist yet, fetch the official one once and save it locally.
if [ ! -f "$FLANNEL_MANIFEST" ]; then
  echo "No local flannel manifest found, downloading official release..."
  curl -sL -o "$FLANNEL_MANIFEST" \
    https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
fi

for i in $(seq 1 20); do
  if kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for API server to accept kubectl..."
  sleep 5
done

for i in $(seq 1 5); do
  if kubectl apply -f "$FLANNEL_MANIFEST"; then
    break
  fi
  echo "kubectl apply failed (attempt $i/5), API server likely still settling after boot -- retrying in 10s..."
  sleep 10
done

echo "Waiting for flannel pods to be ready..."
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=120s || true

# If any flannel pod is still crashlooping (stale state from before),
# force a clean restart once.
BAD_FLANNEL=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep -v "1/1.*Running" | wc -l)
if [ "$BAD_FLANNEL" -gt 0 ]; then
  echo "Some flannel pods unhealthy, forcing restart..."
  kubectl delete pod -n kube-flannel -l app=flannel --force --grace-period=0
  kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=120s || true
fi

echo "Flannel CNI ready."

# Restart Prometheus and Alertmanager on Jenkins EC2
echo ""
echo "--- Restarting Prometheus and Alertmanager ---"
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP "sudo systemctl enable jenkins prometheus alertmanager 2>/dev/null || true"
scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    ~/project/infrarevive/prometheus/prometheus.yml \
    ec2-user@$JENKINS_IP:/tmp/prometheus.yml
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "sudo cp /tmp/prometheus.yml /etc/prometheus/prometheus.yml"

# Deploy alertmanager.yml (has webhook URL for Jenkins recovery trigger)
scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    ~/project/infrarevive/prometheus/alertmanager.yml \
    ec2-user@$JENKINS_IP:/tmp/alertmanager.yml
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "sudo cp /tmp/alertmanager.yml /etc/prometheus/alertmanager.yml"

# Deploy alert.rules.yml -- prometheus.yml references this via rule_files,
# but nothing was ever copying the actual file, so Prometheus silently
# loaded zero alert rules and NodeDown never fired no matter what happened
# to the workers.
scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    ~/project/infrarevive/prometheus/alert.rules.yml \
    ec2-user@$JENKINS_IP:/tmp/alert.rules.yml
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "sudo cp /tmp/alert.rules.yml /etc/prometheus/alert.rules.yml && sudo chown prometheus:prometheus /etc/prometheus/alert.rules.yml"

ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@$JENKINS_IP \
    "sudo systemctl restart prometheus alertmanager"
echo "Prometheus and Alertmanager restarted."

# -------------------------------------------------------
# DEPLOY DASHBOARD TO JENKINS EC2
# -------------------------------------------------------
echo ""
echo "--- Deploying Dashboard to Jenkins EC2 ---"

# Substitute BOTH placeholders. %%MASTER_IP%% is what the dashboard uses to
# tell master vs worker nodes apart -- it used to be a hardcoded IP-substring
# hack, now it's a real comparison against this injected value.
sed -e "s/%%JENKINS_IP%%/$JENKINS_IP/g" \
    -e "s/%%MASTER_IP%%/$MASTER_IP/g" \
    ~/project/infrarevive/dashboard/index.html > /tmp/dashboard_live.html

ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "if ! which nginx > /dev/null 2>&1; then sudo yum install -y nginx > /dev/null 2>&1; fi; \
     sudo mkdir -p /usr/share/nginx/html/infrarevive; \
     sudo systemctl start nginx; \
     sudo systemctl enable nginx > /dev/null 2>&1"

scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    /tmp/dashboard_live.html \
    ec2-user@$JENKINS_IP:/tmp/dashboard_index.html

# Deploy the nginx reverse-proxy config. Without this, the dashboard's
# /api/jenkins, /api/prometheus, /api/alertmanager calls have nothing to
# hit and silently 404, so the dashboard just shows mock data forever.
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ~/project/infrarevive/nginx/infrarevive-nginx.conf \
    ec2-user@$JENKINS_IP:/tmp/nginx.conf

ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && \
     sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf && \
     sudo nginx -t && \
     sudo systemctl reload nginx"

echo "Dashboard + nginx reverse proxy deployed successfully."

# -------------------------------------------------------
# DEPLOY DASHBOARD-API BACKEND (Flask on port 5001)
# Provides real AWS EC2 + Kubernetes node/pod/event data
# to the browser dashboard via the /api/dashboard/ nginx proxy.
# -------------------------------------------------------
echo ""
echo "--- Deploying Dashboard API backend (port 5001) ---"

# Ensure ec2-user has a readable kubeconfig for kubectl calls
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "mkdir -p /home/ec2-user/.kube && \
     sudo cp /var/lib/jenkins/.kube/config /home/ec2-user/.kube/config && \
     sudo chown ec2-user:ec2-user /home/ec2-user/.kube/config && \
     sudo chmod 600 /home/ec2-user/.kube/config"

# Copy dashboard-api source files to Jenkins EC2
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "sudo mkdir -p /opt/infrarevive/dashboard-api && sudo chown -R ec2-user:ec2-user /opt/infrarevive"

scp -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    ~/project/infrarevive/dashboard-api/app.py \
    ~/project/infrarevive/dashboard-api/requirements.txt \
    ~/project/infrarevive/dashboard-api/dashboard-api.service \
    ec2-user@$JENKINS_IP:/tmp/

# Install dependencies, deploy service, and start
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no ec2-user@$JENKINS_IP \
    "sudo cp /tmp/app.py /opt/infrarevive/dashboard-api/ && \
     sudo cp /tmp/requirements.txt /opt/infrarevive/dashboard-api/ && \
     sudo chown -R ec2-user:ec2-user /opt/infrarevive && \
     sudo pip3 install -q flask flask-cors 2>/dev/null || \
       (sudo yum install -y python3-pip > /dev/null 2>&1 && sudo pip3 install -q flask flask-cors) || true && \
     sudo cp /tmp/dashboard-api.service /etc/systemd/system/dashboard-api.service && \
     sudo systemctl daemon-reload && \
     sudo systemctl enable dashboard-api > /dev/null 2>&1 && \
     sudo systemctl restart dashboard-api && \
     echo 'Dashboard API deployed and started on port 5001'"

echo "Dashboard API backend deployed."

# -------------------------------------------------------
# CLEAN UP STALE Unknown PODS (left over from node restart)
# -------------------------------------------------------
echo ""
echo "--- Cleaning up stale Unknown pods ---"
kubectl get pods -n infrarevive --no-headers 2>/dev/null | awk '$3=="Unknown"{print $1}' | xargs -r kubectl delete pod -n infrarevive --force --grace-period=0 || true

echo ""
echo "--- Waiting for app pods to become Ready ---"
kubectl wait --for=condition=Ready pod -n infrarevive --all --timeout=180s || true

# Final status
echo ""
echo "--- Cluster Status ---"
kubectl get nodes || true
kubectl get pods -n kube-flannel || true
kubectl get pods -n infrarevive || true

echo ""
echo "=== EVERYTHING IS BACK UP ==="
echo ""
echo "Jenkins   : http://$JENKINS_IP:8080"
echo "Prometheus: http://$JENKINS_IP:9090"
echo "App       : http://$WORKER0_IP:30080"
echo "API       : http://$WORKER0_IP:30500"
echo ""
echo "================================================"
echo "DASHBOARD  : http://$JENKINS_IP/infrarevive/"
echo "================================================"
echo "Open the dashboard link above in any browser."
echo "Works from any device on any network."
