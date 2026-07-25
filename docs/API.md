# API Documentation

## NGINX Reverse Proxy Endpoints

All API calls from the dashboard browser go through NGINX (port 80) as same-origin requests:

| Proxy Path | Upstream | Purpose |
|-----------|----------|---------|
| `/api/prometheus/` | localhost:9090 | Prometheus query/alert APIs |
| `/api/jenkins/` | localhost:8080 | Jenkins REST API |
| `/api/alertmanager/` | localhost:9093 | Alertmanager v2 API |
| `/api/dashboard/` | localhost:5001 | Dashboard API (Flask) |

## Dashboard API (Flask — port 5001)

Source: `dashboard-api/app.py`

### `GET /health`
Liveness probe.
```json
{ "status": "ok", "service": "infrarevive-dashboard-api" }
```

### `GET /api/k8s/nodes`
Returns enriched Kubernetes node list (via `kubectl get nodes -o json`).

```json
{
  "nodes": [
    {
      "name": "ip-172-20-5-149.ec2.internal",
      "hostname": "ip-172-20-5-149.ec2.internal",
      "role": "master",
      "ready": true,
      "ready_reason": "KubeletReady",
      "internal_ip": "172.20.5.149",
      "external_ip": "",
      "pod_cidr": "10.244.0.0/24",
      "unschedulable": false,
      "kubelet_version": "v1.29.0",
      "container_runtime": "containerd://1.6.19",
      "os_image": "Amazon Linux 2",
      "kernel_version": "5.10.0...",
      "architecture": "amd64",
      "capacity_cpu": "2",
      "capacity_memory": "3975184Ki",
      "capacity_pods": "110",
      "allocatable_cpu": "1900m",
      "allocatable_memory": "3872784Ki",
      "pods_running": 8,
      "creation_timestamp": "2024-01-10T12:00:00Z",
      "conditions": [ { "type": "Ready", "status": "True", "reason": "KubeletReady" } ]
    }
  ],
  "count": 1
}
```

### `GET /api/k8s/pods`
All pods across all namespaces (via `kubectl get pods -A -o json`).

### `GET /api/k8s/events`
Recent cluster events, sorted newest-first, limited to 50 (via `kubectl get events -A`).

### `GET /api/aws/instances`
All EC2 instances tagged `infrarevive-*` (via `aws ec2 describe-instances`).

```json
{
  "instances": [
    {
      "instance_id": "i-0abc123def456",
      "name": "infrarevive-worker-0",
      "state": "running",
      "instance_type": "t3.micro",
      "public_ip": "34.201.35.126",
      "private_ip": "172.20.5.150",
      "availability_zone": "us-east-1a",
      "launch_time": "2024-01-10T12:00:00.000Z",
      "security_groups": ["infrarevive-k8s-sg"],
      "iam_profile": "arn:aws:iam::...:instance-profile/infrarevive-jenkins-profile"
    }
  ],
  "count": 5
}
```

### `GET /api/system/services`
Checks local systemd service health on the Jenkins EC2:

```json
{
  "services": [
    { "name": "Jenkins", "id": "jenkins", "running": true, "status": "Running", "port": 8080, "version": "2.440.1", "uptime": "Wed 2024-01-10 12:00:00 UTC" }
  ],
  "tools": [
    { "name": "Terraform", "id": "terraform", "installed": true, "version": "Terraform v1.6.6" }
  ]
}
```

### `GET /api/recovery/history`
Recent builds of the `infrarevive-recovery` Jenkins job (last 20).

```json
{
  "history": [
    { "build_number": 42, "result": "SUCCESS", "status": "Success", "timestamp": 1704897600000, "duration_ms": 222000, "description": "" }
  ]
}
```

## Prometheus API (via /api/prometheus/)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/prometheus/api/v1/query?query=...` | GET | Instant vector query |
| `/api/prometheus/api/v1/query_range?query=...&start=...&end=...&step=...` | GET | Range vector query (for graphs) |
| `/api/prometheus/api/v1/alerts` | GET | All alerts (firing + pending) |
| `/api/prometheus/api/v1/targets` | GET | Scrape target health |

**Key queries used by the dashboard:**
- CPU: `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
- RAM: `(1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) * 100`
- Disk: `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100`
- Network: `rate(node_network_receive_bytes_total{device!~"lo|docker.*"}[5m]) * 8 / 1000000`
- Node up: `up{job="node-exporter"}`

## Jenkins API (via /api/jenkins/)

| Endpoint | Purpose |
|----------|---------|
| `/api/jenkins/api/json?tree=jobs[name]` | List all Jenkins jobs |
| `/api/jenkins/job/<name>/lastBuild/api/json` | Last build details (result, duration, number) |
| `/api/jenkins/job/<name>/<build>/wfapi/describe` | Pipeline stage breakdown |
| `/api/jenkins/computer/api/json` | Executor/agent info |
| `/api/jenkins/queue/api/json` | Build queue |

## Alertmanager API (via /api/alertmanager/)

| Endpoint | Purpose |
|----------|---------|
| `/api/alertmanager/api/v2/status` | Version, uptime, config |
| `/api/alertmanager/api/v2/silences` | Active silences |
| `/api/alertmanager/api/v2/alerts` | All alerts |

## Flask Application API (in Kubernetes, port 5000/NodePort 30500)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check (`{"status":"ok"}`) |
| `/result/<name>` | GET | Get student result by name |
| `/init-db` | GET | Initialize DB with sample data |
