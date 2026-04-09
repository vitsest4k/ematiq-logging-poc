#!/usr/bin/env bash
# ============================================================
# Ematiq Logging PoC — Full setup script
#
# Builds the k3d cluster from scratch and deploys:
#   ClickHouse (ClickHouse Kubernetes Operator) + Keeper
#   MinIO (S3 cold tier)
#   Vector Agent (DaemonSet) + Vector Aggregator
#   Grafana with dashboards
#   Log generator workloads (apps, external)
#
# Access after setup:
#   Grafana:    http://localhost:3000  (admin / admin)
#   ClickHouse: http://localhost:8123/play
#   MinIO:      http://localhost:9001  (minioadmin / minioadmin)
#
# Persistence: k3d containers are set to restart=unless-stopped.
#   After a reboot, wait ~2 min for Docker + k3s to initialise —
#   all services will come back automatically.
#   ⚠ Ensure Docker Desktop → Settings → "Start at Login" is ON.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="ematiq-logging-poc"

# ── helpers ──────────────────────────────────────────────────
log()  { echo ""; echo "══════════════════════════════════════════"; echo "▶  $*"; echo "══════════════════════════════════════════"; }
info() { echo "   $*"; }

wait_rollout() {
  local kind="$1" name="$2" ns="$3"
  kubectl rollout status "${kind}/${name}" -n "$ns" --timeout=300s
}

wait_pod_label() {
  local ns="$1" label="$2" timeout="${3:-300}"
  info "Waiting for pod -l ${label} in ns=${ns}..."
  kubectl wait pod -n "$ns" -l "$label" --for=condition=Ready --timeout="${timeout}s"
}

# ────────────────────────────────────────────────────────────
# 1. k3d cluster
# ────────────────────────────────────────────────────────────
log "Step 1/12 — k3d cluster"

if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  info "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  info "Creating cluster with port mappings..."
  k3d cluster create "$CLUSTER_NAME" \
    --port "3000:30000@loadbalancer" \
    --port "8123:30001@loadbalancer" \
    --port "9001:30002@loadbalancer" \
    --wait

  info "Setting Docker restart=unless-stopped for persistence across reboots..."
  # shellcheck disable=SC2046
  docker update --restart=unless-stopped \
    $(docker ps -aq --filter "name=k3d-${CLUSTER_NAME}") \
    && info "Restart policy set."
fi

kubectl cluster-info --context "k3d-${CLUSTER_NAME}"

# ────────────────────────────────────────────────────────────
# 2. cert-manager  (required for ClickHouse operator webhooks)
# ────────────────────────────────────────────────────────────
log "Step 2/12 — cert-manager"

if kubectl get namespace cert-manager &>/dev/null && \
   kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
  info "cert-manager already installed — skipping"
else
  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update jetstack
  helm install cert-manager jetstack/cert-manager \
    --create-namespace \
    --namespace cert-manager \
    --set crds.enabled=true \
    --wait
fi

wait_rollout deployment cert-manager cert-manager
wait_rollout deployment cert-manager-webhook cert-manager
wait_rollout deployment cert-manager-cainjector cert-manager

# ────────────────────────────────────────────────────────────
# 3. ClickHouse Kubernetes Operator (clickhouse.com/v1alpha1)
# ────────────────────────────────────────────────────────────
log "Step 3/12 — ClickHouse Kubernetes Operator"

if kubectl get crd clickhouseclusters.clickhouse.com &>/dev/null; then
  info "ClickHouse operator CRDs already present — skipping"
else
  info "Installing ClickHouse Inc operator (github.com/ClickHouse/clickhouse-operator)..."
  kubectl apply -f "https://github.com/ClickHouse/clickhouse-operator/releases/latest/download/clickhouse-operator.yaml"
  info "Waiting for operator CRDs to be established..."
  sleep 10
fi

# Operator lives in clickhouse-operator-system namespace
kubectl rollout status deployment/clickhouse-operator-controller-manager \
  -n clickhouse-operator-system --timeout=120s

# ────────────────────────────────────────────────────────────
# 4. Namespaces
# ────────────────────────────────────────────────────────────
log "Step 4/12 — Namespaces"

for ns in logging monitoring apps external; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  info "  namespace/$ns ready"
done

# ────────────────────────────────────────────────────────────
# 5. MinIO
# ────────────────────────────────────────────────────────────
log "Step 5/12 — MinIO"

kubectl apply -f minio.yaml
wait_rollout deployment minio logging

# ────────────────────────────────────────────────────────────
# 6. ClickHouse storage ConfigMap
# ────────────────────────────────────────────────────────────
log "Step 6/12 — ClickHouse storage ConfigMap"

kubectl apply -f clickhouse-storage-config.yaml

# ────────────────────────────────────────────────────────────
# 7. ClickHouse Keeper
# ────────────────────────────────────────────────────────────
log "Step 7/12 — ClickHouse Keeper"

kubectl apply -f keeper.yaml

info "Waiting for Keeper pod (app.kubernetes.io/name=clickhouse-keeper)..."
kubectl wait pod -n logging -l "app.kubernetes.io/name=clickhouse-keeper" \
  --for=condition=Ready --timeout=180s

# ────────────────────────────────────────────────────────────
# 7a. MinIO bucket  (must exist BEFORE ClickHouse starts)
# ────────────────────────────────────────────────────────────
log "Step 7a — Create MinIO bucket: clickhouse-cold"
# ClickHouse validates S3 disk access at startup — if the bucket is missing it crashes.
# Create the bucket now while ClickHouse is not yet deployed.

kubectl delete job minio-bucket-init -n logging --ignore-not-found

kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-bucket-init
  namespace: logging
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:RELEASE.2024-11-17T19-35-25Z
          command: ["/bin/sh", "-c"]
          args:
            - |
              mc alias set local http://minio.logging.svc.cluster.local:9000 minioadmin minioadmin
              mc mb --ignore-existing local/clickhouse-cold
              echo "Bucket clickhouse-cold is ready"
YAML

kubectl wait job/minio-bucket-init -n logging \
  --for=condition=Complete --timeout=120s

# ────────────────────────────────────────────────────────────
# 8. ClickHouse Cluster
# ────────────────────────────────────────────────────────────
log "Step 8/12 — ClickHouse Cluster"

kubectl apply -f clickhouse-cluster.yaml

info "Waiting for ClickHouse pod (may take 2-3 min)..."
kubectl wait pod -n logging -l "app=logs-clickhouse" \
  --for=condition=Ready --timeout=300s

CH_POD=$(kubectl get pod -n logging -l "app=logs-clickhouse" \
  -o jsonpath='{.items[0].metadata.name}')
info "ClickHouse pod: $CH_POD"

# ────────────────────────────────────────────────────────────
# 8a. Create ClickHouse logs table
# ────────────────────────────────────────────────────────────
log "Step 8a — Create ClickHouse logs table"

kubectl exec -n logging "$CH_POD" -- clickhouse-client --query "
CREATE TABLE IF NOT EXISTS default.logs
(
    timestamp   DateTime64(9),
    service     LowCardinality(String),
    env         LowCardinality(String),
    host        String,
    level       LowCardinality(String),
    message     String,
    fields      Map(String, String)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (service, timestamp)
TTL timestamp + INTERVAL 1 MINUTE TO VOLUME 'cold',
    timestamp + INTERVAL 30 DAY DELETE
SETTINGS storage_policy = 'tiered';
"

info "Table created. Verifying..."
kubectl exec -n logging "$CH_POD" -- \
  clickhouse-client --query "SHOW TABLES IN default;"

info "Storage policies:"
kubectl exec -n logging "$CH_POD" -- \
  clickhouse-client --query \
  "SELECT policy_name FROM system.storage_policies" 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# 9. NodePort services for demo access
# ────────────────────────────────────────────────────────────
log "Step 9/12 — NodePort services"

# ClickHouse → localhost:8123
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: clickhouse-nodeport
  namespace: logging
spec:
  type: NodePort
  selector:
    app: logs-clickhouse
  ports:
    - name: http
      port: 8123
      targetPort: 8123
      nodePort: 30001
YAML

# MinIO console → localhost:9001
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: minio-console-nodeport
  namespace: logging
spec:
  type: NodePort
  selector:
    app: minio
  ports:
    - name: console
      port: 9001
      targetPort: 9001
      nodePort: 30002
YAML

# ────────────────────────────────────────────────────────────
# 10. Vector Agent (DaemonSet) + Aggregator
# ────────────────────────────────────────────────────────────
log "Step 10/12 — Vector Agent + Aggregator"

helm repo add vector https://helm.vector.dev 2>/dev/null || true
helm repo update vector

if helm status vector -n logging &>/dev/null; then
  info "Upgrading Vector Agent..."
  helm upgrade vector vector/vector --namespace logging -f vector-values.yaml
else
  helm install vector vector/vector --namespace logging -f vector-values.yaml
fi
kubectl rollout status daemonset/vector -n logging --timeout=120s

if helm status vector-aggregator -n logging &>/dev/null; then
  info "Upgrading Vector Aggregator..."
  helm upgrade vector-aggregator vector/vector --namespace logging -f aggregator-values.yaml
else
  helm install vector-aggregator vector/vector --namespace logging -f aggregator-values.yaml
fi
kubectl rollout status statefulset/vector-aggregator -n logging --timeout=120s

kubectl apply -f aggregator-svc.yaml

# ────────────────────────────────────────────────────────────
# 11. Grafana
# ────────────────────────────────────────────────────────────
log "Step 11/12 — Grafana"

helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana

if helm status grafana -n logging &>/dev/null; then
  info "Upgrading Grafana..."
  helm upgrade grafana grafana/grafana --namespace logging -f grafana-values.yaml
else
  helm install grafana grafana/grafana --namespace logging -f grafana-values.yaml
fi

wait_rollout deployment grafana logging

# Apply dashboard ConfigMaps (in monitoring namespace — sidecar searches ALL)
kubectl apply -f grafana-dashboards/log-overview.yaml
kubectl apply -f grafana-dashboards/trading.yaml

# ────────────────────────────────────────────────────────────
# 12. Workloads
# ────────────────────────────────────────────────────────────
log "Step 12/12 — Workloads"

kubectl apply -f workloads/app-log-generator.yaml
kubectl apply -f workloads/trading-log-generator.yaml
kubectl apply -f workloads/external-log-generator.yaml

kubectl rollout status deployment/app-log-generator -n apps --timeout=120s
kubectl rollout status deployment/trading-log-generator -n apps --timeout=120s
kubectl rollout status deployment/external-log-generator -n external --timeout=120s

# ────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║              SETUP COMPLETE ✓                         ║"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  Grafana:    http://localhost:3000                     ║"
echo "║              login: admin / admin                     ║"
echo "║                                                        ║"
echo "║  ClickHouse: http://localhost:8123/play               ║"
echo "║                                                        ║"
echo "║  MinIO:      http://localhost:9001                     ║"
echo "║              login: minioadmin / minioadmin           ║"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  After reboot: wait ~2 min for Docker + k3s to init  ║"
echo "║  then all URLs above will be available again.         ║"
echo "║                                                        ║"
echo "║  ⚠  Docker Desktop → Settings → 'Start at Login' ON  ║"
echo "╚════════════════════════════════════════════════════════╝"
