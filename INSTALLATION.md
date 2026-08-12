# Installation Guide — First Time Only

This is the one-time setup. You go through it once, on a fresh AWS account and a
fresh machine. After this, you never repeat it — day-to-day you only use
[STARTUP.md](STARTUP.md).

Budget about 60–90 minutes for the first run, most of it waiting on EC2 boots and
`kubeadm`.

---

## 0. What you need before you start

| Requirement | Notes |
|---|---|
| AWS account | Billing enabled. The default instance sizes are small but not all free-tier. |
| AWS IAM user | With EC2, VPC, IAM and S3 permissions, and an access key pair. |
| A Linux machine or WSL | The scripts are bash and use `ssh`, `scp`, `sed`. They will not run in PowerShell. |
| DockerHub account | Only needed if you want the CI/CD pipeline to push images. |
| GitHub repo | Your fork/copy of this project, for the CI/CD webhook. |

---

## 1. Install the local tools

On your machine (Amazon Linux / RHEL shown — use `apt` equivalents on Debian/Ubuntu,
or see [docs/DEBIAN-SETUP.md](docs/DEBIAN-SETUP.md)):

```bash
# Terraform
curl -O https://releases.hashicorp.com/terraform/1.6.6/terraform_1.6.6_linux_amd64.zip
unzip terraform_1.6.6_linux_amd64.zip && sudo mv terraform /usr/local/bin/

# Ansible
sudo yum install -y ansible

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# jq — the scripts parse terraform output JSON with it
sudo yum install -y jq
```

Check everything is on your PATH:

```bash
terraform version && ansible --version && aws --version && kubectl version --client && jq --version
```

---

## 2. Configure AWS

```bash
aws configure
# AWS Access Key ID     : <your key>
# AWS Secret Access Key : <your secret>
# Default region name   : us-east-1
# Default output format : json
```

The region matters. The default AMI in `terraform/variables.tf`
(`ami-0c02fb55956c7d316`, Amazon Linux 2) only exists in `us-east-1`. If you want a
different region you also have to swap the AMI ID.

---

## 3. Create the EC2 key pair

In the AWS Console: **EC2 → Key Pairs → Create key pair**, named exactly
`infrarevive-key`, type RSA, format `.pem`.

Download it and put it where every script expects it:

```bash
mv ~/Downloads/infrarevive-key.pem ~/.ssh/infrarevive-key.pem
chmod 400 ~/.ssh/infrarevive-key.pem
```

The name and the path are both hardcoded across the playbooks and scripts. If you
use a different name, you have to change it in `terraform/variables.tf` and in
`ansible/inventory.ini` generation.

---

## 4. Clone the repo to the expected path

The automation scripts use the absolute path `~/project/infrarevive`. Clone it there:

```bash
mkdir -p ~/project
git clone <your-repo-url> ~/project/infrarevive
cd ~/project/infrarevive
chmod +x *.sh
```

---

## 5. Create the Terraform state bucket

Terraform stores its state in S3 so that the Jenkins recovery pipeline and your
laptop are always looking at the same state file. The backend bucket has to exist
*before* `terraform init` can use it:

```bash
aws s3 mb s3://infrarevive-tfstate --region us-east-1
```

If you pick a different bucket name, update the `backend "s3"` block in
`terraform/main.tf` to match.

---

## 6. Provision the infrastructure

```bash
cd ~/project/infrarevive/terraform
terraform init
terraform plan          # read this — it should create ~15 resources
terraform apply -auto-approve
```

This builds the VPC, public subnet, internet gateway, route table, security groups,
IAM role and instance profile, and five EC2 instances: Jenkins, one Kubernetes
master, and three workers.

The bucket you created in step 5 is also declared as a resource in `main.tf`. On
first apply Terraform will complain that it already exists — import it once and
re-apply:

```bash
terraform import aws_s3_bucket.tfstate infrarevive-tfstate
terraform apply -auto-approve
```

Confirm the outputs are there:

```bash
terraform output
```

---

## 7. Fill in the real IPs

```bash
cd ~/project/infrarevive
./setup-config.sh
```

This reads `terraform output` and writes the live IPs into:

- `.env`
- `ansible/inventory.ini`
- `prometheus/prometheus.yml`

and then copies the dashboard, the dashboard API, the nginx reverse proxy config,
the Alertmanager config and the alert rules onto the Jenkins EC2.

Note that `inventory.ini` and `prometheus.yml` are generated files and are not
committed to git — templates are kept next to them as `.example` files.

---

## 8. Build the Kubernetes cluster

```bash
ansible-playbook -i ansible/inventory.ini ansible/setup-master.yml
ansible-playbook -i ansible/inventory.ini ansible/setup-workers.yml
```

The master playbook runs `kubeadm init`, installs the Flannel CNI and starts
node-exporter. The worker playbook installs containerd and the kube tools, pulls a
fresh join command from the master, and joins each worker.

Verify:

```bash
export KUBECONFIG=~/.kube/config
kubectl get nodes -o wide
```

You should see four nodes, all `Ready`. Give it two or three minutes if the workers
are still `NotReady` — Flannel needs a moment to come up.

---

## 9. Deploy the application

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/secret.yaml
kubectl apply -f kubernetes/persistent-volume.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml

# seed the database with sample rows
kubectl exec -n infrarevive deploy/flask-api -- curl -s localhost:5000/init-db
```

Before you deploy for real, change the password in `kubernetes/secret.yaml`. The
committed value is a base64 placeholder, and base64 is encoding, not encryption.

---

## 10. Bring the monitoring stack up

```bash
./start-all.sh
```

This is also the script you will use every day from now on. It starts the
instances, refreshes the IPs everywhere, repairs the API server certificate,
re-syncs kubeconfig, makes sure Flannel and every worker are healthy, restarts
Prometheus and Alertmanager, and redeploys the dashboard.

---

## 11. Configure Jenkins

Open `http://<JENKINS_IP>:8080`. The initial admin password is on the box:

```bash
ssh -i ~/.ssh/infrarevive-key.pem ec2-user@<JENKINS_IP> \
  "sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
```

Then:

1. **Plugins** — install Pipeline, Git, Docker Pipeline, Kubernetes CLI and
   Generic Webhook Trigger.
2. **Credentials** — add a username/password credential with the ID
   `dockerhub-credentials`.
3. **Pipeline 1 — `infrarevive-cicd`**
   - Pipeline script from SCM, your GitHub repo, script path `Jenkinsfile-CICD`
   - Build trigger: *GitHub hook trigger for GITScm polling*
4. **Pipeline 2 — `infrarevive-recovery`**
   - Pipeline script from SCM, script path `Jenkinsfile-Recovery`
   - Build trigger: *Generic Webhook Trigger*, token `INFRAREVIVE_RECOVERY_TOKEN`
     (this is the token Alertmanager calls — it must match `prometheus/alertmanager.yml`)
5. **GitHub webhook** — in your repo settings, add
   `http://<JENKINS_IP>:8080/github-webhook/`, content type `application/json`.

Also update `DOCKERHUB_USERNAME` and the git URL inside `Jenkinsfile-CICD` so they
point at your own accounts.

---

## 12. Prove that recovery works

Kill a worker on purpose and watch the system heal itself:

```bash
aws ec2 stop-instances --instance-ids <a-worker-instance-id>
```

Then watch the dashboard at `http://<JENKINS_IP>/infrarevive/`. Within 30 seconds
Prometheus should mark the node down, Alertmanager fires the webhook, the recovery
pipeline starts in Jenkins, and in under five minutes you have a fresh worker in
the cluster with the pods rescheduled onto it.

---

## Where things live

| URL | What |
|---|---|
| `http://<JENKINS_IP>/infrarevive/` | Monitoring dashboard |
| `http://<JENKINS_IP>:8080` | Jenkins |
| `http://<JENKINS_IP>:9090` | Prometheus |
| `http://<JENKINS_IP>:9093` | Alertmanager |
| `http://<WORKER_IP>:30080` | Student Result Portal — frontend |
| `http://<WORKER_IP>:30500` | Flask API |

---

## If something goes wrong

Check [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) first — it covers the
failures that actually happen: workers stuck `NotReady`, Flannel crash-looping
after a restart, expired join tokens, the API server certificate not matching a new
public IP, and Prometheus targets going stale.

---

## Shutting down

When you are done for the day, stop the instances so you stop paying for them:

```bash
./stop-all.sh
```

Nothing is destroyed — the S3 state, the EBS volumes and the cluster all survive.
Next time, see [STARTUP.md](STARTUP.md).
