#!/usr/bin/env bash
# Refresh only worker EC2 resources (fast, bounded). Safe to run from Jenkins or start/stop scripts.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
terraform init -reconfigure -input=false > /dev/null
exec timeout -k 30s 4m terraform apply -refresh-only -auto-approve -input=false -lock-timeout=2m \
  -target='aws_instance.k8s_workers[0]' \
  -target='aws_instance.k8s_workers[1]' \
  -target='aws_instance.k8s_workers[2]'
