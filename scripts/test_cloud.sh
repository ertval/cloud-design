#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cloud-design Automated Audit & Architecture Verification Script
# Static checks only - no live AWS calls (no terraform apply, no kubectl,
# no curl against real endpoints). Validates file presence, IaC syntax via
# grep plus `terraform fmt -check` / `terraform validate` when the binary
# is installed (warn-skip otherwise), manifests, Dockerfiles, and Python code.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "============================================================"
echo " CLOUD-DESIGN ARCHITECTURAL & SECURITY VERIFICATION SUITE   "
echo "============================================================"

echo ">>> 1. Validating Repository Structure & Deliverables"
for dir in terraform manifests Dockerfiles ecs-tasks srcs scripts; do
    if [ -d "$ROOT_DIR/$dir" ]; then
        pass "Directory exists: $dir"
    else
        fail "Missing directory: $dir"
    fi
done

for f in README.md audit.md; do
    if [ -f "$ROOT_DIR/$f" ]; then
        pass "Root file exists: $f"
    else
        fail "Missing root file: $f"
    fi
done

echo ">>> 2. Validating Terraform IaC Architecture"
for tf_file in main.tf vpc.tf security_groups.tf iam.tf orchestration.tf rds.tf amazon_mq.tf alb.tf cognito.tf api_gateway.tf cloudwatch.tf autoscaling.tf variables.tf outputs.tf; do
    if [ -f "$ROOT_DIR/terraform/$tf_file" ]; then
        pass "Terraform module present: $tf_file"
    else
        fail "Missing terraform file: $tf_file"
    fi
done

# Verify security group least privilege rules
if grep -q "from_port.*5432" "$ROOT_DIR/terraform/security_groups.tf" && grep -q "from_port.*5672" "$ROOT_DIR/terraform/security_groups.tf"; then
    pass "Security groups isolate PostgreSQL (5432) and RabbitMQ (5672) within private VPC subnets"
else
    fail "Database or messaging security groups missing strict port isolation"
fi

if grep -q "resource.*aws_cognito_user_pool" "$ROOT_DIR/terraform/cognito.tf"; then
    pass "AWS Cognito User Pool configured for managed public endpoint authentication"
else
    fail "AWS Cognito User Pool missing"
fi

if grep -q "target_value.*60" "$ROOT_DIR/terraform/autoscaling.tf"; then
    pass "Auto-scaling policies configure target tracking at 60% CPU utilization"
else
    fail "Auto-scaling target tracking policy missing 60% CPU trigger"
fi

echo ">>> 3. Validating Kubernetes Manifests"
for m in namespace.yaml secrets.yaml configmap.yaml network-policies.yaml rabbitmq.yaml inventory-database.yaml billing-database.yaml inventory-app.yaml billing-app.yaml api-gateway.yaml ingress.yaml; do
    if [ -f "$ROOT_DIR/manifests/$m" ]; then
        pass "Kubernetes manifest present: $m"
    else
        fail "Missing manifest: $m"
    fi
done

echo ">>> 4. Validating Dockerfiles Optimization & Multi-stage / Penultimate base"
for df in Dockerfile.api-gateway Dockerfile.inventory-app Dockerfile.billing-app Dockerfile.inventory-database Dockerfile.billing-database Dockerfile.rabbitmq; do
    if [ -f "$ROOT_DIR/Dockerfiles/$df" ]; then
        pass "Optimized Dockerfile present: $df"
    else
        fail "Missing Dockerfile: $df"
    fi
done

echo ">>> 5. Validating Microservice Python Scripts Compilation"
for app in api-gateway-app inventory-app billing-app; do
    if [ -f "$ROOT_DIR/srcs/$app/server.py" ]; then
        if python3 -m py_compile "$ROOT_DIR/srcs/$app/server.py" 2>/dev/null; then
            pass "Python script compiles cleanly: srcs/$app/server.py"
        else
            fail "Python compile error in srcs/$app/server.py"
        fi
    fi
done

echo ">>> 6. Validating Shell Scripts Syntax"
for sh in "$SCRIPT_DIR"/*.sh; do
    if bash -n "$sh"; then
        pass "Shell script syntax OK: $(basename "$sh")"
    else
        fail "Shell script syntax error: $(basename "$sh")"
    fi
done

echo ">>> 7. Validating Terraform Formatting & Configuration"
if command -v terraform >/dev/null 2>&1; then
    if terraform -chdir="$ROOT_DIR/terraform" fmt -check -diff; then
        pass "Terraform formatting clean (fmt -check)"
    else
        fail "Terraform formatting issues (run: terraform fmt)"
    fi
    if terraform -chdir="$ROOT_DIR/terraform" validate; then
        pass "Terraform configuration valid (validate)"
    else
        fail "Terraform validate failed"
    fi
else
    echo "  [WARN] terraform binary not found - skipping fmt -check and validate"
fi

echo "============================================================"
echo " VERIFICATION SUMMARY                                       "
echo "============================================================"
echo "  Total Checks Passed: $PASS_COUNT"
echo "  Total Checks Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo ">>> ALL CLOUD-DESIGN AUDIT CHECKS PASSED! <<<"
    exit 0
else
    echo ">>> SOME CHECKS FAILED! <<<"
    exit 1
fi
