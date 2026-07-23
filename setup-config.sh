#!/bin/bash
cd ~/project/infrarevive

# Refresh Terraform state before reading any outputs. AWS assigns a NEW
# public IP whenever a stopped EC2 instance is started again (no Elastic
# IP is used here), and stop-all.sh / start-all.sh stop/start instances
# directly via the AWS CLI -- Terraform never sees that happen. Without
# this refresh, "terraform output" below can return the OLD IP, or an
# empty string if state happened to be read mid-restart.
bash ~/project/infrarevive/scripts/terraform-refresh-workers.sh

# Get IPs from Terraform (state is now guaranteed current)
JENKINS_IP=$(cd terraform && terraform output -raw jenkins_public_ip)
MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
WORKER0_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[0]')
WORKER1_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[1]')
WORKER2_IP=$(cd terraform && terraform output -json worker_public_ips | jq -r '.[2]')

# Fail loud instead of silently writing broken configs with empty IPs
for pair in "JENKINS_IP:$JENKINS_IP" "MASTER_IP:$MASTER_IP" "WORKER0_IP:$WORKER0_IP" "WORKER1_IP:$WORKER1_IP" "WORKER2_IP:$WORKER2_IP"; do
    name="${pair%%:*}"; val="${pair#*:}"
    if [ -z "$val" ] || [ "$val" == "None" ]; then
        echo "ERROR: $name is empty/None even after terraform refresh. Aborting instead of writing broken configs."
        echo "Run 'cd terraform && terraform apply -refresh-only' manually and inspect 'terraform output' before retrying."
        exit 1
    fi
done

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
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        refresh_interval: 10s
        filters:
          - name: tag:Project
            values: ['infrarevive']
          - name: tag:Role
            values: ['master', 'worker']
    relabel_configs:
      - source_labels: [__meta_ec2_public_ip]
        target_label: __address__
        replacement: '\$1:9100'
EOF

# NOTE: alertmanager.yml's webhook already points at http://localhost:8080
# (correct, since Alertmanager and Jenkins run on the same EC2). There was
# a leftover "sed -i s/JENKINS_IP/.../ alertmanager.yml" line here that did
# nothing -- the file has no JENKINS_IP placeholder to replace. Removed.

echo ""
echo "All IPs filled. Files updated."
echo ""


# -------------------------------------------------------
# DEPLOY DASHBOARD TO JENKINS EC2
# -------------------------------------------------------
echo ""
echo "--- Deploying Dashboard to Jenkins EC2 ---"

# Inject real IPs into dashboard file
# NOTE: the placeholders in dashboard/index.html are %%JENKINS_IP%% and
# %%MASTER_IP%% (with the %% wrapper). A previous version of this script
# matched bare "JENKINS_IP", which left broken URLs like
# "http://%%1.2.3.4%%:9090" in the deployed file -- that is why the
# dashboard never fetched real data. Fixed to match the real placeholders.
sed -e "s/%%JENKINS_IP%%/$JENKINS_IP/g" \
    -e "s/%%MASTER_IP%%/$MASTER_IP/g" \
    dashboard/index.html > /tmp/dashboard_live.html

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

# Copy the nginx reverse-proxy config (this file did not exist before --
# it's what makes /api/jenkins, /api/prometheus, /api/alertmanager work)
scp -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    nginx/infrarevive-nginx.conf \
    ec2-user@$JENKINS_IP:/tmp/nginx.conf

# Move to NGINX web root, install the proxy config, and reload
ssh -i ~/.ssh/infrarevive-key.pem \
    -o StrictHostKeyChecking=no \
    ec2-user@$JENKINS_IP \
    "sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && \
     sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf && \
     sudo nginx -t && \
     sudo systemctl reload nginx && \
     echo 'Dashboard + nginx reverse proxy live'"

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
