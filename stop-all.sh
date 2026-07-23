#!/bin/bash

echo "=== STOPPING ALL INFRAREVIVE RESOURCES ==="

# Get IPs and IDs from Terraform
cd ~/project/infrarevive/terraform

# Refresh state before reading outputs -- if this is being run shortly
# after a previous stop/start cycle, Terraform's cached public IP for
# Jenkins may be stale (AWS assigns a new one on every start unless an
# Elastic IP is attached). Without this, the SSH call below can silently
# fail against the wrong/old IP (errors are suppressed with 2>/dev/null).
bash ~/project/infrarevive/scripts/terraform-refresh-workers.sh
JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null)
JENKINS_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-jenkins" --query 'Reservations[0].Instances[0].InstanceId' --output text)
MASTER_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-master" --query 'Reservations[0].Instances[0].InstanceId' --output text)
WORKER_IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=infrarevive-worker-*" --query 'Reservations[*].Instances[0].InstanceId' --output text)

cd ~/project/infrarevive

echo "Jenkins  ID : $JENKINS_ID"
echo "Master   ID : $MASTER_ID"
echo "Workers  IDs: $WORKER_IDS"

# Stop Prometheus, Alertmanager and NGINX on Jenkins EC2
echo ""
echo "--- Stopping services on Jenkins EC2 ---"
ssh -i ~/.ssh/infrarevive-key.pem -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@$JENKINS_IP \
    "pkill prometheus || true; \
     pkill alertmanager || true; \
     echo 'Prometheus and Alertmanager stopped'" 2>/dev/null

echo "Services stopped."

# Clear .env file so stale IPs are not reused
rm -f ~/project/infrarevive/.env
echo "Cleared .env (IPs will be refetched on next start)"

# Stop all EC2 instances
echo ""
echo "--- Stopping all EC2 instances ---"
aws ec2 stop-instances --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS

echo ""
echo "=== ALL INSTANCES STOPPING ==="
echo "They take 30-60 seconds to fully stop."
echo ""

# Wait and confirm
sleep 30
aws ec2 describe-instances \
  --instance-ids $JENKINS_ID $MASTER_ID $WORKER_IDS \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],State.Name]' \
  --output table

echo ""
echo "S3 bucket and Terraform state are UNTOUCHED."
echo "Dashboard will be unavailable until next start."
echo "Run ./start-all.sh to bring everything back."

