#!/bin/bash
# =============================================================================
# InfraRevive — deploy-dashboard.sh
# Standalone dashboard deploy script — run this when you only need to
# redeploy the dashboard without restarting everything
# Usage: ./deploy-dashboard.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${YELLOW}InfraRevive — Deploying Dashboard...${NC}"

# Source IPs from .env if it exists
if [ -f .env ]; then
    source .env
    echo -e "${GREEN}IPs loaded from .env${NC}"
else
    # Refresh Terraform state before reading any outputs -- AWS assigns a
    # NEW public IP whenever a stopped instance is started again, and
    # start-all.sh/stop-all.sh do that via the AWS CLI directly, bypassing
    # Terraform. Without this, "terraform output" below can return a stale
    # or empty IP.
    cd terraform
    terraform init -reconfigure -input=false > /dev/null
    terraform apply -refresh-only -auto-approve
    JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null)
    MASTER_IP=$(terraform output -raw master_public_ip 2>/dev/null)
    WORKER0_IP=$(terraform output -json worker_public_ips 2>/dev/null | jq -r '.[0]')
    cd ..

    if [ -z "$JENKINS_IP" ] || [ "$JENKINS_IP" == "None" ]; then
        echo -e "${RED}ERROR: Cannot get Jenkins IP even after terraform refresh. Run ./start.sh first.${NC}"
        exit 1
    fi
fi

# Inject real IPs into dashboard.
# NOTE: placeholders in dashboard/index.html are %%JENKINS_IP%% / %%MASTER_IP%%
# (with the %% wrapper) -- matching bare "JENKINS_IP" here used to leave
# broken "%%1.2.3.4%%" URLs in the deployed file, which is why the dashboard
# never showed real data. Fixed to match the real placeholders.
sed -e "s/%%JENKINS_IP%%/${JENKINS_IP}/g" \
    -e "s/%%MASTER_IP%%/${MASTER_IP}/g" \
    dashboard/index.html > /tmp/dashboard_live.html

# Deploy to Jenkins EC2
ssh -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    ec2-user@${JENKINS_IP} \
    'sudo mkdir -p /usr/share/nginx/html/infrarevive'

scp -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    /tmp/dashboard_live.html \
    ec2-user@${JENKINS_IP}:/tmp/dashboard_index.html

# Copy the nginx reverse-proxy config (missing before -- required for
# /api/jenkins, /api/prometheus, /api/alertmanager to work at all)
scp -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    nginx/infrarevive-nginx.conf \
    ec2-user@${JENKINS_IP}:/tmp/nginx.conf

ssh -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    ec2-user@${JENKINS_IP} \
    'sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && \
     sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf && \
     sudo nginx -t && \
     sudo systemctl reload nginx'

echo ""
echo -e "${GREEN}Dashboard deployed successfully.${NC}"
echo ""
echo -e "${CYAN}Open in browser: http://${JENKINS_IP}/infrarevive/${NC}"
echo ""

