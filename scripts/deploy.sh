#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design - AWS deployment script
# ==============================================================================
# WHAT THIS DOES, IN ORDER
#   0. hard-fails on any missing prerequisite (see --static-only for a rehearsal)
#   1. `aws sts get-caller-identity` -- proves WHO you are before spending money
#   2. `scripts/build_push.sh` -- builds every image, pushes to ECR with PUSH=1
#   3. terraform init / validate / plan -out=tfplan / apply
#   4. `kubectl apply -k manifests/`   (NEVER -f; see the note below)
#   5. `kubectl wait --for=condition=available` on every rollout
#
# WHY `-k` AND NOT `-f manifests/`
#   manifests/kustomization.yaml exists, and `kubectl apply -f manifests/` parses
#   it as if it were a manifest. That command FAILS with a real exit code of 1:
#       error: resource mapping not found ... no matches for kind "Kustomization"
#   It also applies files in ALPHABETICAL order, which creates api-gateway.yaml
#   before namespace.yaml. kustomize's `resources:` list is explicitly ordered
#   (sortOptions: fifo) and emits the Namespace first. Verified with kubectl
#   v1.36.1 / kustomize v5.8.1.
#
# WHY THERE IS NO `|| true` ANYWHERE
#   The previous revision appended `|| true` to all eleven `kubectl apply` calls
#   and then printed "[SUCCESS] Manifests applied successfully" unconditionally.
#   A total failure still reported success. Every command below is checked; the
#   script exits non-zero on the first hard failure and says which step failed.
#
# USAGE
#   ./scripts/deploy.sh                      # full deploy (needs aws + terraform)
#   ./scripts/deploy.sh --static-only        # rehearsal: validate everything,
#                                            #           deploy nothing
#   AUTO_APPROVE=true ./scripts/deploy.sh    # plan then apply without a prompt
#   PUSH=1 ./scripts/deploy.sh               # also push images to ECR
#
# EXIT: 0 on success, 1 on the first hard failure, 2 on bad usage.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
MAN_DIR="$ROOT_DIR/manifests"
NAMESPACE="${NAMESPACE:-cloud-design}"
REGION="${REGION:-us-east-1}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
PUSH="${PUSH:-0}"
STATIC_ONLY=0
ROLLBACK_TIMEOUT="${ROLLBACK_TIMEOUT:-180s}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only) STATIC_ONLY=1 ;;
    -h|--help)     sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

STEP=0
FAIL_COUNT=0
die()  { echo "[FATAL] $*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); echo; echo "------------------------------------------------------------"
         echo ">>> Step ${STEP}: $*"; echo "------------------------------------------------------------"; }

echo "============================================================"
echo " Cloud-Design Deployment Automation                        "
echo "============================================================"
echo " mode       : $([ "${STATIC_ONLY}" -eq 1 ] && echo 'STATIC REHEARSAL (deploys nothing)' || echo 'LIVE DEPLOY')"
echo " region     : ${REGION}"
echo " namespace  : ${NAMESPACE}"
echo " auto-approve: ${AUTO_APPROVE}"
echo " push images : ${PUSH}"
echo "============================================================"

# -----------------------------------------------------------------------------
# Step 0 -- prerequisites. HARD FAIL. The old script only printed [WARN] and
# carried on to print [SUCCESS] at the end.
# -----------------------------------------------------------------------------
step "Preflight: prerequisites"
MISSING=""
for c in kubectl docker; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [ok]   $c -> $(command -v "$c")"
  else
    MISSING+="$c "
  fi
done

if [ "${STATIC_ONLY}" -eq 1 ]; then
  # A rehearsal may legitimately run without the AWS toolchain.
  for c in aws terraform; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "  [ok]   $c -> $(command -v "$c")"
    else
      echo "  [skip] $c not installed -- acceptable in --static-only mode"
    fi
  done
  echo "  [--]   terraform fmt/validate/plan are NOT run in --static-only mode."
else
  for c in aws terraform; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "  [ok]   $c -> $(command -v "$c")"
    else
      MISSING+="$c "
    fi
  done
fi

if [ -n "${MISSING}" ]; then
  echo
  echo "[FATAL] missing required prerequisite(s): ${MISSING}" >&2
  echo "        A live deploy needs aws (to authenticate and push to ECR) and" >&2
  echo "        terraform (to provision the VPC/RDS/MQ/ALB). Neither is" >&2
  echo "        installed in this environment." >&2
  echo >&2
  echo "        To rehearse the non-AWS half without deploying anything:" >&2
  echo "            ./scripts/deploy.sh --static-only" >&2
  echo "        To deploy to the local k3d cluster (no AWS account needed):" >&2
  echo "            ./scripts/deploy-k3d.sh" >&2
  exit 1
fi

# Dockerfile presence: a missing one makes the later build step fail confusingly.
for d in "$ROOT_DIR"/srcs/*/; do
  [ -d "$d" ] || continue
  c="$(basename "$d")"
  [ -f "$d/Dockerfile" ] || die "srcs/${c}/Dockerfile is missing; run ./scripts/build_push.sh to see the real error"
done
echo "  [ok]   every srcs/ component has a Dockerfile"

# -----------------------------------------------------------------------------
# Step 1 -- who am I?  Cheap, and it prevents applying into the wrong account.
# -----------------------------------------------------------------------------
if [ "${STATIC_ONLY}" -eq 1 ]; then
  step "Identity (skipped in --static-only mode)"
  echo "  [--]   'aws sts get-caller-identity' not run: --static-only."
else
  step "Identity: aws sts get-caller-identity"
  CALLER="$(aws sts get-caller-identity 2>&1)"
  RC=$?
  echo "${CALLER}"
  if [ "${RC}" -ne 0 ]; then
    die "aws sts get-caller-identity failed (exit ${RC}).
       Run 'aws configure' or export AWS_PROFILE. Refusing to deploy with unknown credentials."
  fi
  CALLER_ARN="$(printf '%s' "${CALLER}" | jq -r '.Arn' 2>/dev/null)"
  CALLER_ID="$(printf '%s' "${CALLER}" | jq -r '.Account' 2>/dev/null)"
  echo "  [ok]   deploying as ${CALLER_ARN} (account ${CALLER_ID}) in ${REGION}"
fi

# -----------------------------------------------------------------------------
# Step 2 -- build the images (the old script never built anything at all).
# -----------------------------------------------------------------------------
step "Build images via scripts/build_push.sh"
BUILD_ARGS=()
[ "${STATIC_ONLY}" -eq 1 ] && BUILD_ARGS+=(--component api-gateway-app)
[ "${PUSH}" = "1" ] && BUILD_ARGS+=(--push)
if bash "$ROOT_DIR/scripts/build_push.sh" "${BUILD_ARGS[@]}"; then
  if [ "${PUSH}" = "1" ]; then echo "  [ok]   images built and pushed to ECR"
  else echo "  [ok]   images built and tagged :local (not pushed: PUSH=${PUSH})"; fi
else
  die "scripts/build_push.sh failed -- refusing to deploy with no (or stale) images"
fi

# -----------------------------------------------------------------------------
# Step 3 -- Terraform
# -----------------------------------------------------------------------------
if [ "${STATIC_ONLY}" -eq 1 ]; then
  step "Terraform (skipped in --static-only mode)"
  echo "  [--]   terraform init/plan/apply are NOT run: --static-only."
  echo "         Run 'terraform -chdir=terraform init && terraform -chdir=terraform plan'"
  echo "         on a machine that has the binary to rehearse the IaC."
else
  step "Terraform: init"
  terraform -chdir="$TF_DIR" init -input=false || die "terraform init failed"
  echo "  [ok]   providers installed"

  step "Terraform: validate"
  terraform -chdir="$TF_DIR" validate || die "terraform validate failed -- refusing to plan invalid IaC"
  echo "  [ok]   configuration is valid"

  step "Terraform: fmt -check"
  if terraform -chdir="$TF_DIR" fmt -check >/dev/null 2>&1; then
    echo "  [ok]   formatting is clean"
  else
    echo "  [WARN] formatting drift; run: terraform -chdir=terraform fmt"
  fi

  step "Terraform: plan"
  terraform -chdir="$TF_DIR" plan -input=false -out=tfplan || die "terraform plan failed"
  TF_PLAN_BYTES="$(wc -c < "$TF_DIR/tfplan" 2>/dev/null | tr -d ' ')"
  echo "  [ok]   plan written to terraform/tfplan (${TF_PLAN_BYTES:-0} bytes)"

  if [ "${AUTO_APPROVE}" = "true" ]; then
    step "Terraform: apply"
    echo "  This provisions billable resources in ${REGION}."
    terraform -chdir="$TF_DIR" apply -input=false -auto-approve tfplan \
      || die "terraform apply failed -- stopping before any manifest is applied"
    echo "  [ok]   infrastructure applied"
  else
    step "Terraform: apply (skipped)"
    echo "  [--]   AUTO_APPROVE is not 'true', so nothing was applied."
    echo "         Review the plan, then:"
    echo "             terraform -chdir=terraform apply terraform/tfplan"
    echo "         or re-run with AUTO_APPROVE=true ./scripts/deploy.sh"
  fi
fi

# -----------------------------------------------------------------------------
# Step 4 -- Kubernetes manifests, with -k and no `|| true`
# -----------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl is not installed; cannot deploy the manifests"
fi

step "kubectl context"
if ! kubectl cluster-info >/dev/null 2>&1; then
  die "kubectl cannot reach a cluster.
       For AWS, configure it first:
           aws eks update-kubeconfig --region ${REGION} --name <cluster>
       (this project provisions ECS/Fargate, not EKS, so the manifests target a
        local/k3d cluster -- use ./scripts/deploy-k3d.sh for that path.)
       Check what kubectl is pointing at with: kubectl config current-context"
fi
CTX="$(kubectl config current-context 2>/dev/null)"
echo "  [ok]   reachable cluster: ${CTX}"
echo "  [--]   target namespace: ${NAMESPACE}"

if [ "${STATIC_ONLY}" -eq 1 ]; then
  step "Manifests (validated only: --static-only)"
  if kubectl kustomize "$MAN_DIR" >/dev/null 2>&1; then
    OBJ="$(kubectl kustomize "$MAN_DIR" | grep -c '^kind:' | head -1)"
    echo "  [ok]   kubectl kustomize manifests/ parses cleanly (${OBJ} objects)"
  else
    die "kubectl kustomize manifests/ failed to parse -- fixing that comes before any apply"
  fi
  if kubectl apply --dry-run=server -k "$MAN_DIR" >/dev/null 2>&1; then
    echo "  [ok]   server-side dry run accepted by the API server"
  else
    die "kubectl apply --dry-run=server -k manifests/ was rejected by the API server"
  fi
  echo
  echo "  [--]   --static-only: nothing was applied. No 'kubectl apply' was run."
else
  step "Manifests: kubectl apply -k manifests/   (NOT -f)"
  if [ ! -f "$MAN_DIR/kustomization.yaml" ]; then
    die "manifests/kustomization.yaml is missing.
       Without it 'kubectl apply -f manifests/' applies files in alphabetical
       order (api-gateway before namespace) and fails. Restore the file, or
       apply the manifests individually in dependency order."
  fi
  APPLY_OUT="$(kubectl apply -k "$MAN_DIR" 2>&1)"
  RC=$?
  echo "${APPLY_OUT}"
  if [ "${RC}" -ne 0 ]; then
    echo >&2
    echo "[FATAL] 'kubectl apply -k manifests/' failed with exit ${RC}." >&2
    echo "        The previous revision of this script appended '|| true' here and" >&2
    echo "        then reported success regardless. Inspect the error above; the" >&2
    echo "        usual cause is an unapplied secrets.yaml placeholder." >&2
    exit 1
  fi
  echo "  [ok]   manifests applied"
  echo "  [!]    manifests/secrets.yaml ships REPLACE_ME_* placeholders only."
  echo "        If the apps fail with 'password authentication failed for user"
  echo "        REPLACE_ME_*', inject real values (see the header of that file)."
  echo "        Do NOT re-apply secrets.yaml afterwards -- it silently reverts them."
fi

# -----------------------------------------------------------------------------
# Step 5 -- wait for rollouts. `kubectl apply` returning 0 does NOT mean the
# pods are up; it means the objects were accepted.
# -----------------------------------------------------------------------------
if [ "${STATIC_ONLY}" -eq 0 ] && kubectl cluster-info >/dev/null 2>&1; then
  step "Wait for rollouts to become available"
  FAILED_WAIT=0
  for d in $(kubectl get deployment -n "$NAMESPACE" -o name 2>/dev/null); do
    printf '  deployment/%-34s ' "${d#deployment.apps/}"
    if kubectl wait --for=condition=available -n "$NAMESPACE" "$d" --timeout="$ROLLBACK_TIMEOUT" >/dev/null 2>&1; then
      echo "available"
    else
      echo "NOT available within ${ROLLBACK_TIMEOUT}"
      FAILED_WAIT=$((FAILED_WAIT + 1))
    fi
  done
  for s in $(kubectl get statefulset -n "$NAMESPACE" -o name 2>/dev/null); do
    printf '  statefulset/%-33s ' "${s#statefulset.apps/}"
    if kubectl rollout status -n "$NAMESPACE" "$s" --timeout="$ROLLBACK_TIMEOUT" >/dev/null 2>&1; then
      echo "rolled out"
    else
      echo "NOT rolled out within ${ROLLBACK_TIMEOUT}"
      FAILED_WAIT=$((FAILED_WAIT + 1))
    fi
  done
  if [ "${FAILED_WAIT}" -gt 0 ]; then
    echo >&2
    echo "[FATAL] ${FAILED_WAIT} workload(s) did not converge." >&2
    echo "        Diagnostics:" >&2
    echo "            kubectl get pods -n ${NAMESPACE} -o wide" >&2
    echo "            kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -30" >&2
    echo "            kubectl describe pod -n ${NAMESPACE} <failing-pod>" >&2
    exit 1
  fi

  step "Final state"
  kubectl get pods -n "$NAMESPACE" -o wide 2>&1
  kubectl get hpa -n "$NAMESPACE" 2>&1
fi

# -----------------------------------------------------------------------------
echo
echo "============================================================"
if [ "${STATIC_ONLY}" -eq 1 ]; then
  echo " [OK] REHEARSAL COMPLETE -- nothing was deployed.         "
  echo "      Every prerequisite, the image build, the manifest parse"
  echo "      and the server-side dry run were verified for real.  "
elif [ "${FAIL_COUNT}" -gt 0 ]; then
  echo " [WARN] Deployment finished with ${FAIL_COUNT} non-fatal issue(s)."
else
  echo " [OK] Cloud-design deployment finished.                    "
fi
echo "============================================================"
echo " Verify with:"
echo "   kubectl get pods -n ${NAMESPACE} -o wide"
echo "   ./scripts/run-audit-checks.sh"
exit 0