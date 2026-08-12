# Startup Guide — Every Time After the First

Once the cluster exists, you never repeat the installation. Daily use is two
commands: one to bring everything up, one to put it back to sleep.

If this is your very first run, go to [INSTALLATION.md](INSTALLATION.md) instead.

---

## Bring everything up

```bash
cd ~/project/infrarevive
./start-all.sh
```

Give it four to six minutes. When it finishes it prints the dashboard URL.

---

## What that script is actually doing

It is not just `aws ec2 start-instances`. Stopping and starting EC2 breaks several
things at once, and `start-all.sh` repairs all of them in order:

1. **Reads instance IDs from Terraform state**, not from AWS Name tags. Tags go
   stale after a destroy/recreate cycle — terminated instances stay visible in the
   AWS API for up to an hour and can match the same tag.
2. **Starts every instance** and waits for the `running` state.
3. **Refetches the public IPs.** A stopped EC2 instance gets a brand new public IP
   when it starts again, so every IP written down last session is now wrong.
4. **Rewrites `.env`, `ansible/inventory.ini` and `prometheus/prometheus.yml`** with
   the new values. Prometheus targets use *private* IPs on purpose — those survive
   stop/start, so alerting doesn't silently break every morning.
5. **Waits for real SSH readiness** on the master and Jenkins. EC2 reports `running`
   well before `sshd` is actually accepting connections.
6. **Regenerates the Kubernetes API server certificate** for the new master public
   IP. Without this, `kubectl` fails certificate validation, because the old cert
   has yesterday's IP in its SANs.
7. **Copies the fresh kubeconfig** to your machine and to the Jenkins EC2, pointing
   at the new master IP.
8. **Deletes ghost nodes** — node objects left in `NotReady` from the previous
   session.
9. **Re-joins any worker that isn't really in the cluster.** It compares each
   worker's private IP against `kubectl get nodes`; anything missing gets a fresh
   `kubeadm token create --print-join-command` and an Ansible run. Already-joined
   workers are detected and skipped, so it is safe to run every time.
10. **Makes sure Flannel is healthy**, restarting the DaemonSet if any pod is
    crash-looping — the usual cause of pods stuck in `ContainerCreating` after a
    restart.
11. **Redeploys the Prometheus config, alert rules and Alertmanager config** to the
    Jenkins EC2 and restarts both services.
12. **Redeploys the dashboard, the dashboard API and the nginx reverse proxy** with
    the new IPs substituted into the HTML.

---

## Check that it came up clean

```bash
export KUBECONFIG=~/.kube/config

kubectl get nodes -o wide              # 4 nodes, all Ready
kubectl get pods -n infrarevive -o wide # flask-api, frontend, mysql all Running
kubectl get pods -n kube-flannel        # every flannel pod 1/1 Running
```

Then open the dashboard. Every tile should be showing real numbers, the LIVE pill
should be ticking, and the cluster status should read healthy.

| URL | What |
|---|---|
| `http://<JENKINS_IP>/infrarevive/` | Monitoring dashboard |
| `http://<JENKINS_IP>:8080` | Jenkins |
| `http://<JENKINS_IP>:9090` | Prometheus — check *Status → Targets*, all should be UP |
| `http://<JENKINS_IP>:9093` | Alertmanager |
| `http://<WORKER_IP>:30080` | The application |

The IPs are printed by the script, and are also in `.env`:

```bash
cat ~/project/infrarevive/.env
```

---

## Redeploy only the dashboard

If you edited `dashboard/index.html` or `dashboard-api/app.py` and just want those
back on the server without a full restart:

```bash
./deploy-dashboard.sh
```

---

## Shut everything down

```bash
./stop-all.sh
```

This stops the monitoring services on the Jenkins EC2 first — otherwise
Prometheus keeps scraping instances that are shutting down and fires a false
`NodeDown`, which would trigger the recovery pipeline against a node you stopped on
purpose. Then it clears `.env` so stale IPs are never reused, and stops all five
instances.

Terraform state, the S3 bucket and all EBS volumes are left untouched. Nothing is
destroyed.

---

## Common first-run-of-the-day problems

**`kubectl` says the certificate is not valid for the IP**
The master's public IP changed and the cert wasn't regenerated. Re-run
`./start-all.sh` — step 6 fixes exactly this.

**A worker is stuck `NotReady`**
Usually Flannel. Check `kubectl get pods -n kube-flannel -o wide`, then
`kubectl describe node <name>`. Running `./start-all.sh` again is safe and will
re-join and repair it.

**Prometheus shows targets DOWN**
The new private IPs may not have made it into `/etc/prometheus/prometheus.yml` on
the Jenkins box. Re-run `./start-all.sh`, or check the file directly over SSH.

**The dashboard loads but every panel is empty**
The nginx reverse proxy is what makes `/api/jenkins`, `/api/prometheus` and
`/api/alertmanager` work. Check `sudo nginx -t` and
`sudo systemctl status nginx dashboard-api` on the Jenkins EC2.

**The recovery pipeline fired when I stopped instances myself**
Run `./stop-all.sh` rather than stopping instances from the AWS console — it stops
Alertmanager before the nodes go away.

Anything else, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
