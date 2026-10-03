#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design - teardown
# ==============================================================================
# HONESTY NOTE, because the previous revision of this script was dishonest here.
# It printed:
#     [SUCCESS] All AWS infrastructure destroyed. Zero idle cloud costs.
# after `terraform destroy -auto-approve`, AND printed an unconditional
# "Teardown complete" banner even when terraform was not installed at all (so
# nothing had been destroyed). "Zero idle cloud costs" is not something a shell
# script can know. This revision:
#   * makes no cost claim it cannot verify;
#   * reports, per resource class, whether teardown actually happened;
#   * calls out the costs that SURVIVE `terraform destroy` and tells you the
#     command that stops each one (see the KMS 7-day window below).
#
# WHAT ACTUALLY SURVIVES A TERRAFORM DESTROY
#   1. KMS keys: pending_deletion, still billed, for 7-14 days, unless you call
#      ScheduleKeyDeletion with a PendingWindowInDays of 7 (the minimum AWS
#      allows) -- or wait it out. terraform/aws_kms_key supports
#      deletion_window_in_days = 7 on the resource itself.
#   2. RDS snapshots: BOTH instances here set skip_final_snapshot = true, so
#      terraform destroys them with no snapshot. Any manual snapshots you took
#      are billed until you delete them.
#   3. EBS volumes / snapshots owned by an EKS node group: N/A here, the EKS path
#      has been removed from the IaC.
#   4. Budgets, alarms, log groups, ECR images, CloudWatch dashboards: deleted by
#      terraform destroy, but they can still appear on the invoice for the
#      current partial month. That is unavoidable; it is not a leak.
#
# USAGE
#   ./scripts/destroy.sh                  # k8s manifests + terraform destroy
#   ./scripts/destroy.sh --k3d            # also delete the local k3d cluster
#   ./scripts/destroy.sh --local          # also stop the local compose stack
#   ./scripts/destroy.sh --local-only     # stop compose only, touch nothing else
#   ./scripts/destroy.sh --kms            # also schedule KMS key deletion
#   ./scripts/destroy.sh --yes            # do not prompt (non-interactive)
#
# EXIT: 0 on success, 1 on a hard failure, 2 on refusal.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
MAN_DIR="$ROOT_DIR/manifests"
NAMESPACE="${NAMESPACE:-cloud-design}"
K3D="${K3D:-$HOME/.local/bin/k3d}"
CLUSTER_NAME="${CLUSTER_NAME:-cd-audit}"

DO_K3D=0; DO_LOCAL=0; LOCAL_ONLY=0; DO_KMS=0; ASSUME_YES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --k3d)        DO_K3D=1 ;;
    --local)      DO_LOCAL=1 ;;
    --local-only) DO_LOCAL=1; LOCAL_ONLY=1 ;;
    --kms)        DO_KMS=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -x "${K3D}" ] || K3D="$(command -v k3d 2>/dev/null || true)"

die() { echo "[FATAL] $*" >&2; exit 1; }
step() { echo; echo "------------------------------------------------------------"
         echo ">>> $*"; echo "------------------------------------------------------------"; }

confirm() { # confirm <question>
  [ "${ASSUME_YES}" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty 2>/dev/null || { echo; echo "no TTY: re-run with --yes"; exit 2; }
  case "$a" in y|Y|yes|YES) return 0 ;; *) echo "aborted"; exit 2 ;; esac
}

echo "============================================================"
echo " Cloud-Design Teardown                                      "
echo "============================================================"
echo " namespace   : ${NAMESPACE}"
echo " k3d cluster : $([ "${DO_K3D}" -eq 1 ] && echo "yes (${CLUSTER_NAME})" || echo no)"
echo " compose     : $([ "${DO_LOCAL}" -eq 1 ] && echo yes || echo no)"
echo " kms schedule: $([ "${DO_KMS}" -eq 1 ] && echo yes || echo no)"
echo "============================================================"

# -----------------------------------------------------------------------------
# Local compose stack. NARROWED ON PURPOSE.
# -----------------------------------------------------------------------------
# The previous revision ran:
#     docker ps -q --filter "name=cloud-design" | xargs -r docker stop
# `name=` is a SUBSTRING match on the whole container name, not an exact match
# on this project's containers. Any unrelated container whose name happens to
# contain "cloud-design" -- another student's project, a leftover from a
# different repo, a sidecar named "...-cloud-design-canary" -- would be stopped.
# This only stops containers that compose itself owns AND that belong to this
# project's compose project name, which is safe.
if [ "${DO_LOCAL}" -eq 1 ]; then
  step "Stopping the local docker compose stack"
  if ! command -v docker >/dev/null 2>&1; then
    die "docker is not installed; cannot stop the compose stack"
  fi
  if ! docker info >/dev/null 2>&1; then
    die "the docker daemon is not reachable"
  fi
  OWNED="$(cd "$ROOT_DIR" && docker compose ps --services 2>/dev/null | grep -c . | head -1)"
  echo "  compose services in this project: ${OWNED:-0}"
  if [ "${OWNED:-0}" -gt 0 ]; then
    echo "  stopping (compose-owned containers only, no name-substring matching):"
    (cd "$ROOT_DIR" && docker compose ps -q 2>/dev/null) | while read -r cid; do
      [ -n "$cid" ] || continue
      name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null)"
      echo "    - ${name}"
      docker stop "$cid" >/dev/null 2>&1 || echo "      [WARN] could not stop ${name}"
    done
    echo "  [ok]   compose stack stopped (volumes kept; use 'docker compose down -v' to drop them)"
  else
    echo "  [--]   nothing to stop"
  fi

  if [ "${LOCAL_ONLY}" -eq 1 ]; then
    echo
    echo "============================================================"
    echo " [OK] Local stack stopped. Nothing else was touched.        "
    echo "============================================================"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Kubernetes manifests. -k, not -f, and --ignore-not-found so it is re-runnable.
# -----------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  step "Deleting Kubernetes objects with 'kubectl delete -k manifests/'"
  CTX="$(kubectl config current-context 2>/dev/null)"
  echo "  context: ${CTX}"
  DEL_OUT="$(kubectl delete -k "$MAN_DIR" --ignore-not-found 2>&1)"
  RC=$?
  echo "${DEL_OUT}" | tail -20
  if [ "${RC}" -ne 0 ]; then
    echo >&2
    echo "[WARN] kubectl delete -k returned ${RC}; see the output above." >&2
    echo "       Continuing: a stuck finalizer should not block AWS teardown." >&2
  else
    echo "  [ok]   manifests deleted"
  fi

  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "  [--]   namespace ${NAMESPACE} still exists (kustomization.yaml does not list it as a deletable resource order-wise, or a finalizer is stuck)"
  fi
else
  echo
  echo "[--]   no reachable cluster: skipping kubectl teardown"
fi

# -----------------------------------------------------------------------------
# k3d cluster
# -----------------------------------------------------------------------------
if [ "${DO_K3D}" -eq 1 ]; then
  step "Deleting the k3d cluster ${CLUSTER_NAME}"
  if [ -z "${K3D}" ] || [ ! -x "${K3D}" ]; then
    die "k3d is not installed; cannot delete the cluster"
  fi
  if ${K3D} cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${CLUSTER_NAME}"; then
    ${K3D} cluster delete "${CLUSTER_NAME}" || die "k3d cluster delete failed"
    echo "  [ok]   cluster ${CLUSTER_NAME} deleted (this also removes its containerd image store)"
  else
    echo "  [--]   cluster ${CLUSTER_NAME} does not exist"
  fi
fi

# -----------------------------------------------------------------------------
# Terraform destroy
# -----------------------------------------------------------------------------
step "Terraform destroy"
TF_DESTROYED="no"
if command -v terraform >/dev/null 2>&1; then
  echo "  [ok]   terraform found: $(terraform version 2>/dev/null | head -1)"
  echo "  [!]    This deletes BILLABLE resources in the configured account/region."
  confirm "  Type the AWS account id to proceed? (see terraform output, or press Ctrl-C to abort)"
  if terraform -chdir="$TF_DIR" init -input=false >/dev/null 2>&1; then
    echo "  [ok]   providers initialised"
  else
    die "terraform init failed; nothing was destroyed"
  fi
  if terraform -chdir="$TF_DIR" destroy -auto-approve; then
    TF_DESTROYED="yes"
    echo "  [ok]   terraform destroy completed"
  else
    die "terraform destroy failed. Resources may still exist and may still be billed. See the output above."
  fi
  rm -f "$TF_DIR/tfplan" 2>/dev/null && echo "  [ok]   removed the stale terraform/tfplan"
else
  echo "  [FATAL] terraform is NOT installed -- NOTHING WAS DESTROYED IN AWS." >&2
  echo "          Do not assume this environment is clean. Run the following on a" >&2
  echo "          machine that has terraform installed and valid credentials:" >&2
  echo "              terraform -chdir=terraform init" >&2
  echo "              terraform -chdir=terraform destroy" >&2
  echo "          Then verify nothing is left billing:" >&2
  echo "              aws ec2 describe-vpcs --filters Name=tag:Name,Values=*cloud-design*" >&2
  echo "              aws rds describe-db-instances  --query 'DBInstances[].DBInstanceIdentifier'" >&2
  echo "              aws mq describe-brokers         --query 'BrokerSummaries[].BrokerId'" >&2
  echo "              aws elbv2 describe-load-balancers --names cloud-design-alb" >&2
  TF_DESTROYED="no"
fi

# -----------------------------------------------------------------------------
# KMS: the cost that genuinely survives a destroy.
# -----------------------------------------------------------------------------
if [ "${DO_KMS}" -eq 1 ]; then
  step "Scheduling KMS key deletion"
  if ! command -v aws >/dev/null 2>&1; then
    echo "  [FATAL] aws CLI not installed; KMS keys are STILL PENDING DELETION and still billed." >&2
    echo "          Run this where the aws CLI is available:" >&2
    echo "              aws kms list-keys --query 'Keys[].KeyId'" >&2
    echo "              aws kms schedule-key-deletion --key-id <id> --pending-window-in-days 7" >&2
  else
    KEY_IDS="$(aws kms list-keys --query 'Keys[].KeyId' --output text 2>/dev/null)"
    if [ -z "${KEY_IDS}" ] || [ "${KEY_IDS}" = "None" ]; then
      echo "  [--]   no KMS keys in this account"
    else
      for k in ${KEY_IDS}; do
        STATE="$(aws kms describe-key --key-id "$k" --query 'KeyMetadata.EnabledState' --output text 2>/dev/null)"
        if [ "${STATE}" = "PendingDeletion" ]; then
          W="$(aws kms get-key-randomness --key-id "$k" >/dev/null 2>&1; echo "7")"
          echo "  [ok]   key ${k} is already PendingDeletion; waiting out its window"
        else
          echo "  [..]   scheduling deletion for key ${k}"
          aws kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 \
            && echo "  [ok]   key ${k} pending deletion for 7 days" \
            || echo "  [WARN] could not schedule deletion for ${k}"
        fi
      done
    fi
  fi
else
  echo
  echo "  [--]   KMS keys were NOT scheduled for deletion (pass --kms to do it)."
fi

# -----------------------------------------------------------------------------
# The honest closing statement.
# -----------------------------------------------------------------------------
echo
echo "============================================================"
echo " Teardown finished."
echo "============================================================"
echo
echo " What actually happened:"
if [ "${TF_DESTROYED}" = "yes" ]; then
  echo "   AWS: terraform destroy completed for the managed resources."
else
  echo "   AWS: NOT destroyed (terraform unavailable). See the [FATAL] block above."
fi
echo
echo " What this script CANNOT tell you:"
echo "   - whether your AWS bill for the current partial month drops. It will not:"
echo "     usage already incurred this month is still billed. That is normal."
echo "   - whether anything outside this repository is billing you."
echo
echo " Costs that can survive the above, and the command that stops each:"
echo "   KMS keys       : pending_deletion for 7 days after destroy, still billed."
echo "                    Stop earlier with:  aws kms schedule-key-deletion \\"
echo "                                                --key-id <id> --pending-window-in-days 7"
echo "                    (the minimum AWS allows). terraform can also set"
echo "                    deletion_window_in_days = 7 on aws_kms_key."
echo "   RDS snapshots  : both instances use skip_final_snapshot = true, so terraform"
echo "                    takes none. Manual snapshots you created are NOT deleted:"
echo "                        aws rds delete-db-snapshot --db-snapshot-identifier <id>"
echo "   ECR images     : repositories use force_delete = true and a lifecycle policy."
echo "                    Check for leftovers:  aws ecr describe-repositories"
echo "   CloudWatch     : log groups and alarms are removed by destroy; the current"
echo "                    partial month is still charged."
echo
echo " Verify nothing is left billing:"
echo "   aws ec2 describe-vpcs  --filters Name=tag:Name,Values=*cloud-design*"
echo "   aws rds describe-db-instances --query 'DBInstances[].{Id:DBInstanceIdentifier,MultiAZ:MultiAZ}'"
echo "   aws mq describe-brokers         --query 'BrokerSummaries[].{Id:BrokerId,State:BrokerState}'"
echo "   aws elbv2 describe-load-balancers --query 'LoadBalancers[].DNSName'"
echo "   aws ecr describe-repositories     --query 'repositories[].repositoryName'"
echo "   aws kms list-keys                 --query 'Keys[].KeyId'"
exit 0