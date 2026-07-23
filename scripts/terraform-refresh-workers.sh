#!/usr/bin/env bash
# Synchronize Terraform state after EC2 instances are changed outside Terraform.
# Callers own the overall timeout; never force-kill Terraform during a state write.
set -euo pipefail

cd "$(dirname "$0")/../terraform"
terraform init -reconfigure -input=false
exec terraform apply -refresh-only -auto-approve -input=false -lock-timeout=5m
