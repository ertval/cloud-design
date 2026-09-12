#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cloud-design Resource Teardown Script
# Stops services and destroys AWS resources to avoid ongoing cloud charges
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"

echo "============================================================"
echo " Cloud-Design Resource Teardown & Cost Protection           "
echo "============================================================"

# Step 1: Delete Kubernetes workloads
if [ -d "$ROOT_DIR/manifests" ]; then
    echo "[INFO] Deleting deployed Kubernetes resources..."
    if command -v kubectl &>/dev/null; then
        kubectl delete -f "$ROOT_DIR/manifests/ingress.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/api-gateway.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/billing-app.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/inventory-app.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/billing-database.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/inventory-database.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/rabbitmq.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/network-policies.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/configmap.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/secrets.yaml" --ignore-not-found || true
        kubectl delete -f "$ROOT_DIR/manifests/namespace.yaml" --ignore-not-found || true
    fi
fi

# Step 2: Terraform Destroy
echo "[INFO] Running terraform destroy in $TF_DIR..."
cd "$TF_DIR"

if command -v terraform &>/dev/null; then
    terraform destroy -auto-approve
    echo "[SUCCESS] All AWS infrastructure destroyed. Zero idle cloud costs."
else
    echo "[INFO] Terraform not installed locally. Cleaned up manifests."
fi

# Step 3: Cleanup local plan artifacts and transient containers
rm -f "$TF_DIR/tfplan"

if command -v docker &>/dev/null; then
    echo "[INFO] Stopping any lingering local containers..."
    docker ps -q --filter "name=cloud-design" | xargs -r docker stop 2>/dev/null || true
fi

echo "============================================================"
echo "[SUCCESS] Teardown complete.                                "
echo "============================================================"
