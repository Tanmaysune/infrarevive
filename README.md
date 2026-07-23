# InfraRevive

InfraRevive detects a failed Kubernetes worker, triggers Jenkins through Alertmanager, replaces exactly that worker with Terraform, configures it with Ansible, and verifies that it rejoins the cluster. The dashboard is a read-only, central view of Prometheus, Alertmanager, and Jenkins; it does not send email or trigger recovery itself.

## Runtime flow

1. Prometheus discovers the master and workers by their AWS tags and scrapes node exporter every 5 seconds.
2. `NodeDown` fires after 15 seconds down; Alertmanager waits 2 seconds and sends the webhook to Jenkins.
3. Jenkins identifies the unhealthy worker using AWS state plus its Kubernetes internal IP.
4. Terraform performs one targeted `apply -replace` for that worker. It acquires the remote-state lock once, instead of separately destroying and creating the instance.
5. Jenkins waits for EC2 health checks and SSH, runs Ansible only for the replacement, then requires it to become Kubernetes `Ready`.
6. Prometheus discovers the new tagged worker automatically. The dashboard refreshes every 5 seconds and has a 3.5-second request timeout.

## One-time backend setup

Terraform state locking must exist before the main Terraform directory is initialized.

```bash
cd terraform-bootstrap
terraform init
terraform apply

cd ../terraform
terraform init -reconfigure
```

The bootstrap configuration enables S3 versioning/encryption and creates the DynamoDB lock table. Never run `terraform force-unlock` unless no Terraform process or Jenkins build is active.

## One-time EBS storage migration

MySQL was previously stored in a worker-local `hostPath`; replacing that worker could permanently lose the database. The new manifests use a StatefulSet and an EBS CSI dynamic PVC.

Before applying the new storage manifests, back up the current database:

```bash
kubectl -n infrarevive exec deploy/mysql -- mysqldump -uroot -prootpassword results > results.sql
```

Then apply the Terraform role/profile update, rerun the master playbook to install the EBS CSI driver, and apply the Kubernetes manifests:

```bash
terraform -chdir=terraform apply
ansible-playbook -i ansible/inventory.ini ansible/setup-master.yml --private-key ~/.ssh/infrarevive-key.pem
kubectl apply -f kubernetes/storage-class.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/deployment.yaml
```

Wait for `mysql-0` to be Ready, then restore the backup. Do not delete the old PVC/host data until the restore has been verified.

## Jenkins configuration

Configure the recovery job as **Pipeline script from SCM**, with script path `Jenkinsfile-Recovery`. The Generic Webhook Trigger token must match `INFRAREVIVE_RECOVERY_TOKEN` in `prometheus/alertmanager.yml`. Jenkins needs Terraform, AWS CLI, `jq`, Ansible, Kubectl, SSH access to the instances, and permission to write `/etc/prometheus`.

## Validation runbook

After deployment, run these checks from Jenkins:

```bash
terraform -chdir=terraform init -input=false
terraform -chdir=terraform validate
promtool check config /etc/prometheus/prometheus.yml
kubectl get csidrivers
kubectl -n kube-system get pods -l app=ebs-csi-controller
kubectl -n infrarevive get pvc,pods
```

To test recovery, stop one worker EC2 instance. Confirm one alert, one Jenkins recovery build, a new worker instance, a `Ready` Kubernetes node, and healthy Prometheus targets. Verify the MySQL records after the storage migration.
