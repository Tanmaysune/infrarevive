#!/bin/bash

export AWS_PAGER=""
> ~/.ssh/known_hosts

echo "=== STARTING ALL INFRAREVIVE RESOURCES ==="

# Get instance IDs by tag
JENKINS_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-jenkins" --query 'Reservations[0].Instances[0].InstanceId' --output text)
MASTER_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-master" --query 'Reservations[0].Instances[0].InstanceId' --output text)
WORKER_IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-worker-*" --query 'Reservations[*].Instances[0].InstanceId' --output text)

echo "Jenkins  ID : $JENKINS_ID"
echo "Master   ID : $MASTER_ID"
echo "Workers  IDs: $WORKER_IDS"

# Start all instances
aws ec2 start-instances --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS --output text

echo ""
echo "Waiting for instances to reach running state..."
aws ec2 wait instance-running --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS
echo "All instances are running."

# Fetch new IPs
echo ""
echo "--- Fetching new IPs ---"
JENKINS_IP=$(aws ec2 describe-instances --instance-ids $JENKINS_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MASTER_IP=$(aws ec2 describe-instances --instance-ids $MASTER_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
WORKER0_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-worker-0" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
WORKER1_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-worker-1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
WORKER2_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-worker-2" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "Jenkins  : $JENKINS_IP"
echo "Master   : $MASTER_IP"
echo "Worker 0 : $WORKER0_IP"
echo "Worker 1 : $WORKER1_IP"
echo "Worker 2 : $WORKER2_IP"

# Save IPs to .env for other scripts
cat > ~/project/infrarevive/.env << EOF
JENKINS_IP=$JENKINS_IP
MASTER_IP=$MASTER_IP
WORKER0_IP=$WORKER0_IP
WORKER1_IP=$WORKER1_IP
WORKER2_IP=$WORKER2_IP
EOF

# Update inventory.ini
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

# Update kubeconfig with new master IP
echo ""
echo "--- Updating kubeconfig ---"
echo "Waiting 45 seconds for SSH to be ready on master..."
sleep 45
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@$MASTER_IP:/home/ec2-user/.kube/config \
    ~/.kube/config
sed -i "s|server: https://.*:6443|server: https://$MASTER_IP:6443|" ~/.kube/config
echo "kubeconfig updated."

# Restart Prometheus and Alertmanager on Jenkins EC2
echo ""
echo "--- Restarting Prometheus and Alertmanager ---"
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@$JENKINS_IP \
    "pkill prometheus || true; pkill alertmanager || true; sleep 2; \
     nohup prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/tmp/prometheus-data > /tmp/prometheus.log 2>&1 & \
     nohup alertmanager --config.file=/etc/alertmanager/alertmanager.yml --web.listen-address=':9093' > /tmp/alertmanager.log 2>&1 & \
     echo done"
echo "Prometheus and Alertmanager restarted."

# -------------------------------------------------------
# DEPLOY DASHBOARD TO JENKINS EC2
# Inject real Jenkins IP into dashboard then copy to NGINX
# -------------------------------------------------------
echo ""
echo "--- Deploying Dashboard to Jenkins EC2 ---"

# Replace JENKINS_IP placeholder with real IP in dashboard
sed "s/JENKINS_IP/$JENKINS_IP/g" ~/project/infrarevive/dashboard/index.html > /tmp/dashboard_live.html

# Ensure NGINX is installed and running on Jenkins EC2
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "if ! which nginx > /dev/null 2>&1; then sudo yum install -y nginx > /dev/null 2>&1; fi; \
     sudo mkdir -p /usr/share/nginx/html/infrarevive; \
     sudo systemctl start nginx; \
     sudo systemctl enable nginx > /dev/null 2>&1"

# Copy dashboard with real IP injected
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    /tmp/dashboard_live.html \
    ec2-user@$JENKINS_IP:/tmp/dashboard_index.html

# Move to NGINX web root
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && \
     sudo systemctl reload nginx"

echo "Dashboard deployed successfully."

# Final status
echo ""
echo "--- Cluster Status ---"
sleep 10
kubectl get nodes
kubectl get pods -n infrarevive

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
