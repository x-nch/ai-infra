# Phase 6: Monitoring

**Duration**: 1-2 hours | **Severity**: 1 Fix (Resource optimization)

---

## Overview

This phase sets up lightweight monitoring with Prometheus and Grafana, optimized for a 3-node home cluster (instead of resource-heavy kube-prometheus-stack).

## Prerequisites

- k3s cluster running (Phase 1-3 complete)
- vLLM deployed (Phase 4 - optional)

---

## T6.1: Lightweight Monitoring Stack

**Fix**: kube-prometheus-stack consumes ~3-4GB RAM. Use standalone Prometheus + Grafana.

```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Prometheus Configuration

```bash
cat > manifests/phase6/prometheus.yml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    
    scrape_configs:
    # Prometheus itself
    - job_name: 'prometheus'
      static_configs:
        - targets: ['localhost:9090']
    
    # Kubernetes nodes
    - job_name: 'kubernetes-nodes'
      kubernetes_sd_configs:
        - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
    
    # Kubernetes pods
    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?:(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
    
    # Ray metrics
    - job_name: 'ray'
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
            - ray-system
            - llm-serving
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_name]
        action: keep
        regex: .*-head.*
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: ray_head_pod
    
    # NVIDIA DCGM Exporter (if installed)
    - job_name: 'nvidia-dcgm'
      static_configs:
        - targets: ['dcgm-exporter.monitoring.svc:9400']
EOF

# Install Prometheus
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  -f manifests/phase6/prometheus.yml \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false \
  --set server.resources.limits.cpu=500m \
  --set server.resources.limits.memory=1Gi \
  --set server.resources.requests.cpu=250m \
  --set server.resources.requests.memory=512Mi
```

### Grafana Installation

```bash
cat > manifests/phase6/grafana.yml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus-server.monitoring.svc:9090
      isDefault: true
      editable: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gpu-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  gpu-dashboard.json: |
    {
      "dashboard": {
        "title": "GPU Monitoring",
        "panels": [
          {
            "title": "GPU Utilization",
            "type": "graph",
            "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
            "targets": [
              {
                "expr": "rate(GPU_Utilization_gpu_id{pod=~\".*-worker.*\"}[5m])",
                "legendFormat": "{{pod}} - GPU {{gpu_id}}"
              }
            ]
          },
          {
            "title": "GPU Memory Used",
            "type": "graph",
            "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
            "targets": [
              {
                "expr": "GPU_Memory_Used_bytes{pod=~\".*-worker.*\"}",
                "legendFormat": "{{pod}} - GPU {{gpu_id}}"
              }
            ]
          }
        ]
      }
    }
EOF

# Install Grafana
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set persistence.enabled=false \
  --set datasources.enabled=true \
  --set datasources.dataSource.Grafana.datasources=null \
  --set sidecar.dashboards.enabled=true \
  --set sidecar.dashboards.label=grafana_dashboard \
  --set adminPassword=admin \
  --set service.type=LoadBalancer \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=512Mi
```

---

## T6.2: GPU DCGM Dashboard

Import NVIDIA DCGM Exporter dashboard and configure GPU metrics.

```bash
# Install DCGM Exporter
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/k8s/dcgm-exporter.yaml

# Verify DCGM exporter is running
kubectl get pods -n monitoring -l app=dcgm-exporter

# Import Grafana dashboard (ID: 12239)
# This can be done via Grafana UI or ConfigMap
```

### DCGM Dashboard ConfigMap

```bash
cat > manifests/phase6/dcgm-dashboard.yml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  dcgm-dashboard.json: |
    {
      "dashboard": {
        "title": "NVIDIA DCGM GPU Dashboard",
        "uid": "dcgm-gpu",
        "version": 1,
        "timezone": "browser",
        "schemaVersion": 16,
        "refresh": "10s",
        "panels": [
          {
            "id": 1,
            "title": "GPU Utilization (%)",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
            "targets": [
              {
                "expr": "GPU_Utilization_gpu_id",
                "legendFormat": "GPU {{gpu_id}}",
                "refId": "A"
              }
            ],
            "yaxes": [
              {"format": "percent", "label": "Utilization", "min": 0, "max": 100}
            ]
          },
          {
            "id": 2,
            "title": "GPU Memory Used (MB)",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
            "targets": [
              {
                "expr": "GPU_Memory_Used_bytes / 1024 / 1024",
                "legendFormat": "GPU {{gpu_id}}",
                "refId": "A"
              }
            ]
          },
          {
            "id": 3,
            "title": "GPU Temperature (C)",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
            "targets": [
              {
                "expr": "GPU_Temperature_gpu_id",
                "legendFormat": "GPU {{gpu_id}}",
                "refId": "A"
              }
            ]
          },
          {
            "id": 4,
            "title": "GPU Power Usage (W)",
            "type": "graph",
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
            "targets": [
              {
                "expr": "GPU_Power_Usage_gpu_id",
                "legendFormat": "GPU {{gpu_id}}",
                "refId": "A"
              }
            ]
          }
        ]
      }
    }
EOF

kubectl apply -f manifests/phase6/dcgm-dashboard.yml
```

---

## Alert Rules

```bash
cat > manifests/phase6/alert-rules.yml << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-alerts
  namespace: monitoring
spec:
  groups:
  - name: gpu-alerts
    rules:
    - alert: GPUHighMemory
      expr: (GPU_Memory_Used_bytes / GPU_Memory_Total_bytes) > 0.9
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "GPU {{ $labels.gpu_id }} memory usage > 90%"
        description: "GPU {{ $labels.gpu_id }} on pod {{ $labels.pod }} is using {{ $value | humanizePercentage }} of memory"
    
    - alert: GPUTemperature
      expr: GPU_Temperature_gpu_id > 85
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "GPU {{ $labels.gpu_id }} temperature > 85C"
        description: "GPU {{ $labels.gpu_id }} on pod {{ $labels.pod }} is at {{ $value }}C"
    
    - alert: GPUNotAvailable
      expr: absent(GPU_Utilization_gpu_id)
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "GPU metrics not available"
        description: "GPU metrics not being scraped for 5 minutes"
EOF

kubectl apply -f manifests/phase6/alert-rules.yml
```

---

## Accessing Dashboards

```bash
# Get Grafana LoadBalancer IP
kubectl get svc -n monitoring grafana

# Default credentials
# Username: admin
# Password: admin (change on first login)

# Access URLs
# Grafana: http://<grafana-ip>:80
# Prometheus: http://<prometheus-ip>:9090
```

---

## Validation Commands

```bash
# Check Prometheus
kubectl get pods -n monitoring -l app=prometheus
kubectl exec -it prometheus-0 -n monitoring -- promtool check config /etc/prometheus/prometheus.yml

# Check Grafana
kubectl get pods -n monitoring -l app=grafana

# Check DCGM exporter
kubectl get pods -n monitoring -l app=dcgm-exporter

# Check for GPU metrics
kubectl exec -it prometheus-0 -n monitoring -- curl localhost:9090/api/v1/query?query=GPU_Utilization_gpu_id
```

---

## Resource Usage

| Component | CPU | Memory |
|-----------|-----|--------|
| Prometheus | 250m | 512Mi |
| Grafana | 250m | 256Mi |
| DCGM Exporter | 100m | 100Mi |
| **Total** | **~600m** | **~870Mi** |

This is significantly lighter than kube-prometheus-stack (~3-4GB RAM).

---

## Next Phase

This completes the monitoring phase. Your AI infrastructure is now fully operational!

### Summary of All Phases

1. ✅ [Cluster Bootstrap](./01-cluster-bootstrap.md) - k3s + MetalLB
2. ✅ [GPU Infrastructure](./02-gpu-infrastructure.md) - NVIDIA GPU Operator
3. ✅ [Storage + KubeRay](./03-storage-kuberay.md) - NFS + Ray
4. ✅ [vLLM + External Access](./04-vllm-external.md) - Inference + HTTPS
5. ⏳ [Training](./05-training.md) - Deferred (needs scoping)
6. ✅ [Monitoring](./06-monitoring.md) - Prometheus + Grafana