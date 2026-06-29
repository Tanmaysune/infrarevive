#!/bin/bash
cd ~/project/infrarevive

# Get IPs from Terraform
JENKINS_IP=$(cd terraform && terraform output -raw jenkins_public_ip)
MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
WORKER0_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[0]')
WORKER1_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[1]')
WORKER2_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[2]')

echo "Jenkins  : $JENKINS_IP"
echo "Master   : $MASTER_IP"
echo "Worker 0 : $WORKER0_IP"
echo "Worker 1 : $WORKER1_IP"
echo "Worker 2 : $WORKER2_IP"

# Save IPs to .env
cat > .env << EOF
JENKINS_IP=$JENKINS_IP
MASTER_IP=$MASTER_IP
WORKER0_IP=$WORKER0_IP
WORKER1_IP=$WORKER1_IP
WORKER2_IP=$WORKER2_IP
EOF

# Auto-fill ansible/inventory.ini
cat > ansible/inventory.ini << EOF
[jenkins]
$JENKINS_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem

[k8s_master]
$MASTER_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem

[k8s_workers]
$WORKER0_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
$WORKER1_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
$WORKER2_IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/infrarevive-key.pem
EOF

# Auto-fill prometheus/prometheus.yml with real IPs
cat > prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

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
          - '${MASTER_IP}:9100'
          - '${WORKER0_IP}:9100'
          - '${WORKER1_IP}:9100'
          - '${WORKER2_IP}:9100'

  - job_name: 'flask-api'
    metrics_path: '/health'
    static_configs:
      - targets: ['${WORKER0_IP}:30500']
EOF

# Auto-fill Jenkins IP in alertmanager placeholder file
sed -i "s/JENKINS_IP/$JENKINS_IP/g" prometheus/alertmanager.yml

echo ""
echo "All IPs filled. Files updated."
echo ""


# -------------------------------------------------------
# DEPLOY DASHBOARD TO JENKINS EC2
# -------------------------------------------------------
echo ""
echo "--- Deploying Dashboard to Jenkins EC2 ---"

# Inject real Jenkins IP into dashboard file
sed "s/JENKINS_IP/$JENKINS_IP/g" dashboard/index.html > /tmp/dashboard_live.html

# Install NGINX on Jenkins EC2 if not already installed
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "if ! which nginx > /dev/null 2>&1; then \
         sudo yum install -y nginx > /dev/null 2>&1; \
         echo 'NGINX installed'; \
     else \
         echo 'NGINX already installed'; \
     fi; \
     sudo mkdir -p /usr/share/nginx/html/infrarevive; \
     sudo systemctl start nginx; \
     sudo systemctl enable nginx > /dev/null 2>&1"

# Copy dashboard to Jenkins EC2
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    /tmp/dashboard_live.html \
    ec2-user@$JENKINS_IP:/tmp/dashboard_index.html

# Move to NGINX web root and reload
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && \
     sudo systemctl reload nginx && \
     echo 'Dashboard live'"

echo ""
echo "=== Setup Complete ==="
echo "inventory.ini    : filled with real IPs"
echo "prometheus.yml   : filled with real IPs"
echo "alertmanager.yml : deployed to Jenkins EC2 with real key"
echo ""
echo "================================================"
echo "DASHBOARD  : http://$JENKINS_IP/infrarevive/"
echo "================================================"
echo "Open the link above in any browser on any device."
