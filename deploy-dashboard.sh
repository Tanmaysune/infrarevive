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
    # Fetch fresh from Terraform
    cd terraform
    JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null)
    WORKER0_IP=$(terraform output -json worker_public_ips 2>/dev/null | jq -r '.[0]')
    cd ..

    if [ -z "$JENKINS_IP" ]; then
        echo -e "${RED}ERROR: Cannot get Jenkins IP. Run ./start.sh first.${NC}"
        exit 1
    fi
fi

# Inject real Jenkins IP into dashboard
sed "s/JENKINS_IP/${JENKINS_IP}/g" dashboard/index.html > /tmp/dashboard_live.html

# Deploy to Jenkins EC2
ssh -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    ec2-user@${JENKINS_IP} \
    'sudo mkdir -p /usr/share/nginx/html/infrarevive'

scp -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    /tmp/dashboard_live.html \
    ec2-user@${JENKINS_IP}:/tmp/dashboard_index.html

ssh -o StrictHostKeyChecking=no \
    -i ~/.ssh/infrarevive-key.pem \
    ec2-user@${JENKINS_IP} \
    'sudo cp /tmp/dashboard_index.html /usr/share/nginx/html/infrarevive/index.html && sudo systemctl reload nginx'

echo ""
echo -e "${GREEN}Dashboard deployed successfully.${NC}"
echo ""
echo -e "${CYAN}Open in browser: http://${JENKINS_IP}/infrarevive/${NC}"
echo ""
