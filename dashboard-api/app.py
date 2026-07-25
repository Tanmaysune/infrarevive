#!/usr/bin/env python3
"""
InfraRevive Dashboard API
=========================
A lightweight Flask backend that runs on the Jenkins EC2 instance and exposes
real infrastructure data to the browser dashboard. The browser cannot call the
AWS API (requires SigV4 signing) or the Kubernetes API (requires client certs)
directly, so this service acts as a secure proxy using the locally-installed
`aws` and `kubectl` CLIs (which already have credentials on the Jenkins host).

Endpoints
---------
GET /health              -> liveness probe
GET /api/k8s/nodes       -> enriched Kubernetes node list (status, IPs, versions, capacity)
GET /api/k8s/pods        -> all pods across namespaces (counts per node)
GET /api/k8s/events      -> recent cluster events (last 50, newest first)
GET /api/aws/instances   -> AWS EC2 instances tagged infrarevive-* (state, IPs, AZ, type)
GET /api/system/services -> local systemd service health (jenkins, prometheus, alertmanager, docker, nginx)

All responses are JSON. Errors return {"error": "..."} with HTTP 500.
"""

import json
import os
import subprocess
import time
import re
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Kubernetes kubeconfig path used by Jenkins pipelines
KUBECONFIG = os.environ.get("KUBECONFIG", "/var/lib/jenkins/.kube/config")

# How long (seconds) to wait for a CLI command before giving up
CLI_TIMEOUT = 20

# Cache TTL in seconds — avoids hammering kubectl/aws on every dashboard poll
CACHE_TTL = 10
_cache = {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def run_cmd(cmd, timeout=CLI_TIMEOUT):
    """Run a shell command and return (stdout, stderr, returncode)."""
    env = os.environ.copy()
    if cmd and "kubectl" in cmd[0]:
        env["KUBECONFIG"] = KUBECONFIG
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return "", "command timed out", 124
    except Exception as exc:
        return "", str(exc), 1


def cached(key, builder):
    """Return cached value if fresh, otherwise call builder() and cache it."""
    now = time.time()
    entry = _cache.get(key)
    if entry and (now - entry["ts"]) < CACHE_TTL:
        return entry["data"]
    data = builder()
    _cache[key] = {"ts": now, "data": data}
    return data


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "infrarevive-dashboard-api"}), 200


# ---------------------------------------------------------------------------
# Kubernetes: Nodes
# ---------------------------------------------------------------------------
@app.route("/api/k8s/nodes")
def k8s_nodes():
    """Return enriched node information from the Kubernetes API."""
    def build():
        stdout, stderr, rc = run_cmd([
            "kubectl", "get", "nodes", "-o", "json", "--kubeconfig", KUBECONFIG
        ])
        if rc != 0:
            return {"error": stderr or "kubectl failed", "nodes": []}

        try:
            raw = json.loads(stdout)
        except json.JSONDecodeError:
            return {"error": "invalid JSON from kubectl", "nodes": []}

        # Build a map of pod counts per node (one extra kubectl call)
        pod_counts = _pod_counts_per_node()

        nodes = []
        for item in raw.get("items", []):
            meta = item.get("metadata", {})
            spec = item.get("spec", {})
            status = item.get("status", {})
            conditions = {c["type"]: c for c in status.get("conditions", [])}

            # Addresses
            addrs = status.get("addresses", [])
            internal_ip = next(
                (a["address"] for a in addrs if a["type"] == "InternalIP"), ""
            )
            external_ip = next(
                (a["address"] for a in addrs if a["type"] == "ExternalIP"), ""
            )
            hostname = next(
                (a["address"] for a in addrs if a["type"] == "Hostname"), meta.get("name", "")
            )

            # Capacity vs allocatable
            cap = status.get("capacity", {})
            alloc = status.get("allocatable", {})

            # Role
            labels = meta.get("labels", {})
            role = "master" if any(k.startswith("node-role.kubernetes.io/control-plane") or k.startswith("node-role.kubernetes.io/master") for k in labels) else "worker"

            ready_cond = conditions.get("Ready", {})
            node_ready = ready_cond.get("status") == "True"

            # Node info block
            ni = status.get("nodeInfo", {})

            node_obj = {
                "name": meta.get("name", ""),
                "hostname": hostname,
                "role": role,
                "ready": node_ready,
                "ready_reason": ready_cond.get("reason", ""),
                "ready_message": ready_cond.get("message", ""),
                "internal_ip": internal_ip,
                "external_ip": external_ip,
                "pod_cidr": spec.get("podCIDR", ""),
                "unschedulable": spec.get("unschedulable", False),
                "kubelet_version": ni.get("kubeletVersion", ""),
                "container_runtime": ni.get("containerRuntimeVersion", ""),
                "os_image": ni.get("osImage", ""),
                "kernel_version": ni.get("kernelVersion", ""),
                "architecture": ni.get("architecture", ""),
                "capacity_cpu": cap.get("cpu", ""),
                "capacity_memory": cap.get("memory", ""),
                "capacity_pods": cap.get("pods", ""),
                "allocatable_cpu": alloc.get("cpu", ""),
                "allocatable_memory": alloc.get("memory", ""),
                "pods_running": pod_counts.get(meta.get("name", ""), 0),
                "creation_timestamp": meta.get("creationTimestamp", ""),
                "conditions": [
                    {"type": c["type"], "status": c["status"], "reason": c.get("reason", ""), "message": c.get("message", "")}
                    for c in status.get("conditions", [])
                ],
            }
            nodes.append(node_obj)

        return {"nodes": nodes, "count": len(nodes)}

    result = cached("k8s_nodes", build)
    return jsonify(result)


def _pod_counts_per_node():
    """Return {node_name: running_pod_count}."""
    stdout, _, rc = run_cmd([
        "kubectl", "get", "pods", "-A", "-o", "json", "--kubeconfig", KUBECONFIG
    ])
    counts = {}
    if rc != 0:
        return counts
    try:
        raw = json.loads(stdout)
    except json.JSONDecodeError:
        return counts
    for item in raw.get("items", []):
        if item.get("status", {}).get("phase") == "Running":
            node = item.get("spec", {}).get("nodeName", "")
            if node:
                counts[node] = counts.get(node, 0) + 1
    return counts


# ---------------------------------------------------------------------------
# Kubernetes: Pods
# ---------------------------------------------------------------------------
@app.route("/api/k8s/pods")
def k8s_pods():
    def build():
        stdout, stderr, rc = run_cmd([
            "kubectl", "get", "pods", "-A", "-o", "json", "--kubeconfig", KUBECONFIG
        ])
        if rc != 0:
            return {"error": stderr or "kubectl failed", "pods": []}
        try:
            raw = json.loads(stdout)
        except json.JSONDecodeError:
            return {"error": "invalid JSON", "pods": []}

        pods = []
        for item in raw.get("items", []):
            meta = item.get("metadata", {})
            spec = item.get("spec", {})
            status = item.get("status", {})
            containers = []
            for c in status.get("containerStatuses", []):
                containers.append({
                    "name": c.get("name", ""),
                    "ready": c.get("ready", False),
                    "restart_count": c.get("restartCount", 0),
                    "state": list((c.get("state") or {}).keys())[0] if c.get("state") else "unknown",
                    "image": c.get("image", ""),
                })
            pods.append({
                "namespace": meta.get("namespace", ""),
                "name": meta.get("name", ""),
                "node": spec.get("nodeName", ""),
                "phase": status.get("phase", ""),
                "pod_ip": status.get("podIP", ""),
                "restarts": sum(c.get("restartCount", 0) for c in status.get("containerStatuses", [])),
                "containers": containers,
                "creation_timestamp": meta.get("creationTimestamp", ""),
            })
        return {"pods": pods, "count": len(pods)}

    result = cached("k8s_pods", build)
    return jsonify(result)


# ---------------------------------------------------------------------------
# Kubernetes: Events
# ---------------------------------------------------------------------------
@app.route("/api/k8s/events")
def k8s_events():
    def build():
        stdout, stderr, rc = run_cmd([
            "kubectl", "get", "events", "-A",
            "--sort-by=.lastTimestamp",
            "-o", "json", "--kubeconfig", KUBECONFIG
        ])
        if rc != 0:
            return {"error": stderr or "kubectl failed", "events": []}
        try:
            raw = json.loads(stdout)
        except json.JSONDecodeError:
            return {"error": "invalid JSON", "events": []}

        events = []
        for item in raw.get("items", []):
            meta = item.get("metadata", {})
            events.append({
                "namespace": meta.get("namespace", ""),
                "name": item.get("involvedObject", {}).get("name", ""),
                "kind": item.get("involvedObject", {}).get("kind", ""),
                "reason": item.get("reason", ""),
                "message": item.get("message", ""),
                "type": item.get("type", ""),
                "last_timestamp": item.get("lastTimestamp", ""),
                "count": item.get("count", 0),
            })
        # Newest first, limit to 50
        events = sorted(events, key=lambda e: e.get("last_timestamp", ""), reverse=True)[:50]
        return {"events": events}

    result = cached("k8s_events", build)
    return jsonify(result)


# ---------------------------------------------------------------------------
# AWS: EC2 Instances
# ---------------------------------------------------------------------------
@app.route("/api/aws/instances")
def aws_instances():
    """Return all EC2 instances tagged infrarevive-* with full details."""
    def build():
        stdout, stderr, rc = run_cmd([
            "aws", "ec2", "describe-instances",
            "--filters", "Name=tag:Name,Values=infrarevive-*",
            "--query", "Reservations[*].Instances[*]",
            "--output", "json"
        ])
        if rc != 0:
            return {"error": stderr or "aws cli failed", "instances": []}
        try:
            raw = json.loads(stdout)
        except json.JSONDecodeError:
            return {"error": "invalid JSON from aws", "instances": []}

        instances = []
        for res in raw:
            for inst in res:
                tags = {t["Key"]: t["Value"] for t in inst.get("tags", [])}
                # Block device mapping for root volume size
                block_devices = inst.get("BlockDeviceMappings", [])
                root_volume_size = ""
                # Public/private IP
                instances.append({
                    "instance_id": inst.get("InstanceId", ""),
                    "name": tags.get("Name", ""),
                    "state": inst.get("State", {}).get("Name", ""),
                    "instance_type": inst.get("InstanceType", ""),
                    "public_ip": inst.get("PublicIpAddress", ""),
                    "private_ip": inst.get("PrivateIpAddress", ""),
                    "availability_zone": inst.get("Placement", {}).get("AvailabilityZone", ""),
                    "subnet_id": inst.get("SubnetId", ""),
                    "vpc_id": inst.get("VpcId", ""),
                    "ami_id": inst.get("ImageId", ""),
                    "key_name": inst.get("KeyName", ""),
                    "launch_time": inst.get("LaunchTime", ""),
                    "security_groups": [sg.get("GroupName", "") for sg in inst.get("SecurityGroups", [])],
                    "iam_profile": inst.get("IamInstanceProfile", {}).get("Arn", ""),
                    "root_device": inst.get("RootDeviceName", ""),
                })
        return {"instances": instances, "count": len(instances)}

    result = cached("aws_instances", build)
    return jsonify(result)


# ---------------------------------------------------------------------------
# System: Local Service Health (on Jenkins EC2)
# ---------------------------------------------------------------------------
@app.route("/api/system/services")
def system_services():
    """Check health of local services via systemctl + HTTP probes."""
    services = [
        {"name": "jenkins", "display": "Jenkins", "port": 8080, "type": "systemd"},
        {"name": "prometheus", "display": "Prometheus", "port": 9090, "type": "systemd"},
        {"name": "alertmanager", "display": "Alertmanager", "port": 9093, "type": "systemd"},
        {"name": "nginx", "display": "NGINX", "port": 80, "type": "systemd"},
        {"name": "docker", "display": "Docker", "port": 0, "type": "systemd"},
        {"name": "dashboard-api", "display": "Dashboard API", "port": 5001, "type": "systemd"},
    ]

    # Tools that are CLI-only (not daemons)
    tools = [
        {"name": "terraform", "display": "Terraform", "cmd": "terraform version"},
        {"name": "kubectl", "display": "Kubectl", "cmd": "kubectl version --client"},
        {"name": "aws", "display": "AWS CLI", "cmd": "aws --version"},
        {"name": "ansible", "display": "Ansible", "cmd": "ansible --version"},
    ]

    result = {"services": [], "tools": []}

    for svc in services:
        stdout, _, rc = run_cmd(["systemctl", "is-active", svc["name"]], timeout=5)
        active = stdout.strip() == "active"
        # Try to get version / uptime
        version = ""
        if svc["name"] == "jenkins":
            version = _jenkins_version()
        elif svc["name"] == "prometheus":
            version = _prometheus_version()
        elif svc["name"] == "alertmanager":
            version = _alertmanager_version()
        elif svc["name"] == "docker":
            version = _docker_version()
        elif svc["name"] == "nginx":
            version = _nginx_version()

        uptime = _service_uptime(svc["name"]) if active else ""

        result["services"].append({
            "name": svc["display"],
            "id": svc["name"],
            "running": active,
            "status": "Running" if active else "Stopped",
            "port": svc["port"],
            "version": version,
            "uptime": uptime,
        })

    for tool in tools:
        stdout, stderr, rc = run_cmd(tool["cmd"].split(), timeout=5)
        version = stdout.strip().split("\n")[0] if rc == 0 else ""
        result["tools"].append({
            "name": tool["display"],
            "id": tool["name"],
            "installed": rc == 0,
            "version": version,
        })

    return jsonify(result)


def _jenkins_version():
    stdout, _, _ = run_cmd(
        ["curl", "-s", "http://localhost:8080/api/json"],
        timeout=5
    )
    try:
        return json.loads(stdout).get("mode", "") if stdout else ""
    except Exception:
        return ""


def _prometheus_version():
    stdout, _, _ = run_cmd(
        ["curl", "-s", "http://localhost:9090/api/v1/status/buildinfo"],
        timeout=5
    )
    try:
        return json.loads(stdout).get("data", {}).get("version", "") if stdout else ""
    except Exception:
        return ""


def _alertmanager_version():
    stdout, _, _ = run_cmd(
        ["curl", "-s", "http://localhost:9093/api/v2/status"],
        timeout=5
    )
    try:
        return json.loads(stdout).get("versionInfo", {}).get("version", "") if stdout else ""
    except Exception:
        return ""


def _docker_version():
    stdout, _, _ = run_cmd(["docker", "--version"], timeout=5)
    return stdout.strip()


def _nginx_version():
    _, stderr, _ = run_cmd(["nginx", "-v"], timeout=5)
    # nginx -v writes to stderr, not stdout
    return stderr.strip() or "nginx"


def _service_uptime(service_name):
    """Get uptime of a systemd service as a human-readable string."""
    stdout, _, _ = run_cmd(
        ["systemctl", "show", service_name, "--property=ActiveEnterTimestamp"],
        timeout=5
    )
    # ActiveEnterTimestamp=Wed 2024-01-10 12:00:00 UTC
    ts = stdout.strip().replace("ActiveEnterTimestamp=", "")
    return ts


# ---------------------------------------------------------------------------
# Recovery: History (from Jenkins recovery job)
# ---------------------------------------------------------------------------
@app.route("/api/recovery/history")
def recovery_history():
    """Fetch recent builds of the recovery Jenkins job and parse timestamps."""
    def build():
        stdout, _, rc = run_cmd([
            "curl", "-s",
            "http://localhost:8080/job/infrarevive-recovery/api/json?tree=builds[number,result,timestamp,duration,description]{0,20}"
        ], timeout=10)
        if rc != 0 or not stdout:
            return {"history": []}
        try:
            data = json.loads(stdout)
        except json.JSONDecodeError:
            return {"history": []}

        history = []
        for b in data.get("builds", []):
            history.append({
                "build_number": b.get("number", 0),
                "result": b.get("result", ""),
                "timestamp": b.get("timestamp", 0),
                "duration_ms": b.get("duration", 0),
                "description": b.get("description", ""),
                "status": "Success" if b.get("result") == "SUCCESS"
                else "Failed" if b.get("result") == "FAILURE"
                else "Running" if b.get("result") is None
                else b.get("result", "Unknown"),
            })
        return {"history": history}

    result = cached("recovery_history", build)
    return jsonify(result)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # Listen on all interfaces so nginx can proxy to it
    app.run(host="0.0.0.0", port=5001, debug=False)
