# Dashboard Documentation

## Overview

The INFRAREVIVE dashboard is a **dark-themed, real-time monitoring single-page application** served via NGINX on the Jenkins EC2 instance. It displays **real data only** — no dummy values, no static JSON, no hardcoded metrics.

**URL**: `http://<JENKINS_IP>/infrarevive/`

## Data Sources

| Data Source | Proxy Path | Backend | What It Provides |
|-------------|-----------|---------|------------------|
| Prometheus | `/api/prometheus/` | localhost:9090 | CPU, RAM, Disk, Network metrics + alerts |
| Jenkins | `/api/jenkins/` | localhost:8080 | Recovery job build status, pipeline stages |
| Alertmanager | `/api/alertmanager/` | localhost:9093 | Active alerts, silences, version |
| Dashboard API | `/api/dashboard/` | localhost:5001 | K8s nodes, pods, events, AWS instances, service health |

All calls are **same-origin** through the NGINX reverse proxy — this avoids CORS issues entirely.

## Views

### 1. Dashboard (Home)
- **Cluster Status Bar**: Overall status (Healthy/Warning/Critical), Total/Healthy/Failed/Master/Worker node counts, Recovery status (IDLE/ACTIVE)
- **System Status Cards**: Jenkins, Prometheus, Alertmanager, NGINX, Docker, Dashboard API, Terraform, Kubernetes, AWS EC2, Ansible — each showing running/stopped, version, port, uptime
- **Live Metrics**: 4 canvas-based line graphs (CPU, RAM, Disk, Network) with per-node color-coded lines, 30-minute range from Prometheus
- **Recovery Status Panel**: Shows "No Active Recovery" (green) or "Recovery In Progress" (amber, pulsing)
- **Alert Summary**: Critical/Warning/Info counts with color-coded stat boxes
- **Cluster Events**: Live Kubernetes events (last 30, with severity dots)
- **Recovery History**: Table of recent recovery runs (node, status, build #, started, duration)

### 2. Cluster Nodes
Full node table with 16 columns:
- Node Name, Role (master/worker), Status (Ready/NotReady)
- Internal IP, External IP, AWS Instance ID, Availability Zone
- EC2 State (running/stopped), CPU %, RAM %, Disk % (with mini progress bars)
- Pods (running/capacity), Kubelet version, Container Runtime, OS, Uptime

**Click any row** to open a detailed modal with:
- All addresses, instance details, capacity/allocatable resources
- CPU/RAM/Disk usage with color thresholds
- Node conditions (Ready, MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable)
- Running pods list (namespace, name, phase, restart count)

### 3. Recovery
- **Timeline**: Visual timeline of all 12 recovery pipeline stages with timestamps
  - Each stage shows: done (green checkmark), running (amber spinner), failed (red X), pending (gray)
  - Stage descriptions explain what happens at each step
- **History Table**: All recovery runs with build #, status, started, duration, description

### 4. Alerts
- Table of all firing alerts: alert name, severity, instance, state, active since, summary

## How Data Matching Works

The dashboard merges data from three sources by IP:

1. **Kubernetes nodes** (from dashboard-api `/api/k8s/nodes`) provide: name, role, ready, internal_ip (private), kubelet_version, container_runtime, os_image, pods_running
2. **AWS EC2 instances** (from dashboard-api `/api/aws/instances`) provide: instance_id, state, availability_zone, instance_type, launch_time — matched by **private_ip** = k8s internal_ip
3. **Prometheus metrics** (instant queries) provide: CPU, RAM, Disk — keyed by `public_ip:9100` (the AWS instance's public IP + node-exporter port)

## Auto-Refresh

- All data refreshes every **15 seconds** via `setInterval(refreshAll, 15000)`
- Graphs fetch 30-minute Prometheus range queries with 15s step
- The "Updated HH:MM:SS" timestamp in the header shows the last successful refresh

## Theme

- **Dark professional UI**: `#070b14` base background, `#131a2b` cards
- **Fonts**: Inter (UI), JetBrains Mono (metrics/data)
- **Color coding**: Green (healthy), Amber (warning), Red (critical), Blue (primary), Purple (master nodes)
- **Responsive**: Collapses sidebar on mobile, adjusts grid layouts at 1024px and 768px breakpoints
