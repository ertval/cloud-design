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
#     command that stops each one.
#
# WHAT ACTUALLY SURVIVES A TERRAFORM DESTROY
#   1. KMS key: NOT a cost survivor. `terraform destroy` schedules it for
#      deletion with deletion_window_in_days = 7 (the minimum AWS allows), and
#      KMS pricing says a key scheduled for deletion is not charged. The only
#      key that keeps costing $1/month is one the destroy missed (a failed run,
#      or a key orphaned by lost state). --kms checks exactly that, for this
#      project's key only.
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
#   ./scripts/destroy.sh --kms            # also check THIS project's KMS key
#                                         # is pending deletion (never other keys)
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
    -h|--help)    sed -n '2,44p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# KEEP `|| true`: `command -v` exits 1 when the OPTIONAL tool is absent, and an
# absent k3d is a supported configuration here (teardown of an EKS/ECS stack, or
# of a cluster that was never created locally). The absence is handled explicitly
# a few lines below by branching on the empty K3D, so swallowing the exit status
# does not swallow a failure.
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

ask() { # ask <question>: like confirm, but "no" (or no TTY) returns 1 instead of exiting
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty 2>/dev/null || { echo; return 1; }
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# FIX: the destroy prompt used to say "Type the AWS account id to proceed?" but
# accepted only y/N, so it never checked which account was about to be emptied.
# It now shows the account, identity and region and requires the account id typed
# back exactly; anything else aborts with nothing destroyed. The aws CLI and
# terraform read the same credential chain (AWS_PROFILE, env, config), so this is
# the account terraform will act on. --yes skips the prompt, as before.
confirm_account() { # confirm_account <region>
  [ "${ASSUME_YES}" -eq 1 ] && return 0
  if ! command -v aws >/dev/null 2>&1; then
    echo "  [!]    the aws CLI is not installed, so the target account cannot be shown."
    confirm "  Destroy every Terraform-managed resource in region ${1:-<unknown>} anyway?"
    return 0
  fi
  local who acct arn typed
  who="$(aws sts get-caller-identity --region "${1:-us-east-1}" \
    --query '[Account,Arn]' --output text 2>&1)" \
    || die "aws sts get-caller-identity failed, so the target account is unknown; nothing was destroyed:
${who}"
  read -r acct arn <<<"${who}"
  echo "  account : ${acct}"
  echo "  identity: ${arn}"
  echo "  region  : ${1:-<unknown>}"
  printf '  Type the account id shown above to destroy everything Terraform manages there (anything else aborts): '
  read -r typed </dev/tty 2>/dev/null || { echo; echo "no TTY: re-run with --yes"; exit 2; }
  if [ "${typed}" != "${acct}" ]; then
    echo "aborted: '${typed}' is not ${acct}. Nothing was destroyed."
    exit 2
  fi
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
# Filled in before the destroy when --kms is set; see the KMS step below.
KMS_READY=0; TF_REGION=""; TF_PROJECT=""; TF_ENV=""; STATE_KEY_IDS=""
if command -v terraform >/dev/null 2>&1; then
  echo "  [ok]   terraform found: $(terraform version 2>/dev/null | head -1)"
  # init first: it changes nothing in AWS, and reading the region needs it.
  if terraform -chdir="$TF_DIR" init -input=false >/dev/null 2>&1; then
    echo "  [ok]   providers initialised"
  else
    die "terraform init failed; nothing was destroyed"
  fi
  # The region is the provider's (var.aws_region), not the aws CLI default.
  tfc() { echo "$1" | terraform -chdir="$TF_DIR" console 2>/dev/null | tr -d '"[:space:]'; }
  TF_REGION="$(tfc var.aws_region)"
  echo "  [!]    This deletes BILLABLE resources in the account below."
  confirm_account "${TF_REGION}"
  if [ "${DO_KMS}" -eq 1 ]; then
    # Read what identifies this project's key NOW: after the destroy the state no
    # longer lists it.
    TF_PROJECT="$(tfc var.project_name)"; TF_ENV="$(tfc var.environment)"
    if command -v jq >/dev/null 2>&1 && [ -n "${TF_REGION}" ] && [ -n "${TF_PROJECT}" ] && [ -n "${TF_ENV}" ]; then
      STATE_KEY_IDS="$(terraform -chdir="$TF_DIR" show -json 2>/dev/null \
        | jq -r '.values.root_module.resources[]? | select(.type == "aws_kms_key") | .values.key_id')"
      KMS_READY=1
      echo "  [ok]   --kms: region ${TF_REGION}; keys in Terraform state: $(echo ${STATE_KEY_IDS:-none})"
    else
      echo "  [WARN] --kms: could not read the region and project from Terraform, or jq is"
      echo "         missing; the KMS step will only print the commands to run by hand."
    fi
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
# KMS: this project's key, and only this project's key.
# -----------------------------------------------------------------------------
# FIX: this used to loop over `aws kms list-keys` with no filter and schedule
# deletion of EVERY customer managed key in the region, including keys of other
# projects in the same account, whose data becomes unrecoverable once the 7 days
# pass. It also claimed a key pending deletion is still billed; KMS pricing says
# it is not. What it does now:
#   * keys Terraform had in state before the destroy: the destroy has already
#     scheduled them, so check that, and schedule one only if it is somehow
#     still Enabled or Disabled.
#   * nothing in state (lost state, or a second run after a destroy): look for
#     customer managed keys that carry ALL of this project's tags (Project,
#     Environment and ManagedBy = Terraform, from local.common_tags). Every
#     other key is only read (describe-key, list-resource-tags), never changed.
#     A match pending deletion is reported; any other match is scheduled only
#     after an interactive yes. Under --yes it is listed, not scheduled: a tag
#     match alone is not proof enough to destroy data unattended.
kms_state() { # prints: KeyState DeletionDate KeyManager (empty if the key is gone)
  aws kms describe-key --region "${TF_REGION}" --key-id "$1" \
    --query 'KeyMetadata.[KeyState,DeletionDate,KeyManager]' --output text 2>/dev/null
}
kms_schedule() { # prints the deletion date
  aws kms schedule-key-deletion --region "${TF_REGION}" --key-id "$1" \
    --pending-window-in-days 7 --query DeletionDate --output text
}
kms_manual() {
  echo "         To check by hand (replace the defaults if terraform.tfvars changes them):"
  echo "             aws resourcegroupstaggingapi get-resources --region <aws_region> \\"
  echo "               --resource-type-filters kms:key \\"
  echo "               --tag-filters Key=Project,Values=${TF_PROJECT:-cloud-design} Key=Environment,Values=${TF_ENV:-prod} \\"
  echo "               --query 'ResourceTagMappingList[].ResourceARN'"
  echo "             aws kms describe-key --key-id <arn> --query 'KeyMetadata.[KeyState,DeletionDate]'"
  echo "         and only for a key from that list that is not PendingDeletion:"
  echo "             aws kms schedule-key-deletion --key-id <arn> --pending-window-in-days 7"
}

if [ "${DO_KMS}" -eq 1 ]; then
  step "KMS: this project's key only"
  if [ "${TF_DESTROYED}" != "yes" ]; then
    echo "  [--]   not checked: terraform destroy did not run. Scheduling the key of a"
    echo "         stack that still exists would make its RDS data and secrets unreadable."
    kms_manual
  elif ! command -v aws >/dev/null 2>&1 || [ "${KMS_READY}" -ne 1 ]; then
    echo "  [--]   not checked: the aws CLI, jq or the Terraform values are missing."
    kms_manual
  elif [ -n "${STATE_KEY_IDS}" ]; then
    for k in ${STATE_KEY_IDS}; do
      read -r st dd km <<<"$(kms_state "$k")"
      case "${st:-}" in
        PendingDeletion)
          echo "  [ok]   ${k}: PendingDeletion (scheduled by terraform destroy), deleted on ${dd}; not billed while pending" ;;
        Enabled|Disabled)
          echo "  [..]   ${k}: still ${st} after the destroy; scheduling deletion (7 days)"
          if dd="$(kms_schedule "$k")"; then
            echo "  [ok]   ${k}: deleted on ${dd}"
          else
            echo "  [WARN] could not schedule ${k}; it keeps costing \$1/month until it is"
          fi ;;
        "")
          echo "  [--]   ${k}: not found, already deleted" ;;
        *)
          echo "  [WARN] ${k}: state ${st}; left alone" ;;
      esac
    done
  else
    echo "  no key in Terraform state; looking for customer managed keys tagged"
    echo "  Project=${TF_PROJECT} Environment=${TF_ENV} ManagedBy=Terraform in ${TF_REGION}"
    if ! ALL_KEYS="$(aws kms list-keys --region "${TF_REGION}" --query 'Keys[].KeyId' --output text 2>&1)"; then
      echo "  [WARN] aws kms list-keys failed: ${ALL_KEYS}"
      kms_manual
      ALL_KEYS=""
    fi
    SCANNED=0; MATCHED=0
    for k in ${ALL_KEYS}; do
      [ "$k" = "None" ] && continue
      SCANNED=$((SCANNED + 1))
      read -r st dd km <<<"$(kms_state "$k")"
      [ "${km:-}" = "CUSTOMER" ] || continue
      TAGS="$(aws kms list-resource-tags --region "${TF_REGION}" --key-id "$k" --output json 2>/dev/null)" || continue
      printf '%s' "${TAGS}" | jq -e --arg p "${TF_PROJECT}" --arg e "${TF_ENV}" \
        '([.Tags[]? | {(.TagKey): .TagValue}] | add // {}) as $t
         | $t.Project == $p and $t.Environment == $e and $t.ManagedBy == "Terraform"' >/dev/null || continue
      MATCHED=$((MATCHED + 1))
      case "${st:-}" in
        PendingDeletion)
          echo "  [ok]   ${k}: PendingDeletion, deleted on ${dd}; not billed while pending" ;;
        Enabled|Disabled)
          if [ "${ASSUME_YES}" -eq 1 ]; then
            echo "  [!]    ${k} carries this project's tags and is ${st}. NOT scheduled under --yes."
            echo "         If no stack uses it any more:"
            echo "             aws kms schedule-key-deletion --region ${TF_REGION} --key-id ${k} --pending-window-in-days 7"
          elif ask "  ${k} carries this project's tags and is ${st}. Schedule its deletion (7 days)?"; then
            if dd="$(kms_schedule "$k")"; then
              echo "  [ok]   ${k}: deleted on ${dd}"
            else
              echo "  [WARN] could not schedule ${k}"
            fi
          else
            echo "  [--]   ${k} left as it is"
          fi ;;
        *)
          echo "  [WARN] ${k}: state ${st}; left alone" ;;
      esac
    done
    echo "  [--]   ${SCANNED} key(s) in ${TF_REGION} read, ${MATCHED} carry this project's tags; no other key was changed"
  fi
else
  echo
  echo "  [--]   --kms not set: this project's KMS key was not checked."
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
echo "   KMS key        : terraform destroy schedules it for deletion in 7 days (the"
echo "                    minimum AWS allows); a key pending deletion is not billed."
echo "                    Only a key the destroy missed keeps costing \$1/month."
echo "                    --kms checks this project's key (and no other)."
echo "   RDS snapshots  : both instances use skip_final_snapshot = true, so terraform"
echo "                    takes none. Manual snapshots you created are NOT deleted:"
echo "                        aws rds delete-db-snapshot --db-snapshot-identifier <id>"
echo "   ECR images     : repositories use force_delete = true and a lifecycle policy."
echo "                    Check for leftovers:  aws ecr describe-repositories"
echo "   S3 bucket      : force_destroy = true deletes every object version (the ALB"
echo "                    access logs) before the bucket itself."
echo "                    Check for leftovers:  aws s3 ls | grep ${TF_PROJECT:-cloud-design}"
echo "   CloudWatch     : log groups and alarms are removed by destroy; the current"
echo "                    partial month is still charged."
echo
echo " Verify nothing is left billing:"
echo "   aws ec2 describe-vpcs  --filters Name=tag:Name,Values=*cloud-design*"
echo "   aws rds describe-db-instances --query 'DBInstances[].{Id:DBInstanceIdentifier,MultiAZ:MultiAZ}'"
echo "   aws mq describe-brokers         --query 'BrokerSummaries[].{Id:BrokerId,State:BrokerState}'"
echo "   aws elbv2 describe-load-balancers --query 'LoadBalancers[].DNSName'"
echo "   aws ecr describe-repositories     --query 'repositories[].repositoryName'"
echo "   aws s3api list-buckets --query \"Buckets[?contains(Name, '${TF_PROJECT:-cloud-design}')].Name\""
echo "   aws resourcegroupstaggingapi get-resources --resource-type-filters kms:key \\"
echo "     --tag-filters Key=Project,Values=${TF_PROJECT:-cloud-design} --query 'ResourceTagMappingList[].ResourceARN'"
exit 0