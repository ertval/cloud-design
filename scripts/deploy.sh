#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design - AWS deployment script (ECS on Fargate)
# ==============================================================================
# WHAT THIS DOES, IN ORDER
#   0. hard-fails on any missing prerequisite (aws, terraform, docker, jq)
#   1. `aws sts get-caller-identity` -- proves WHO you are before spending money
#   2. terraform init / validate / fmt -check, and reads aws_region from Terraform
#   3. `terraform plan` of the whole stack. Without AUTO_APPROVE=true the script
#      STOPS here and nothing billable has been created.
#   With AUTO_APPROVE=true it continues:
#   4. `terraform apply -target=aws_ecr_repository.app` -- the three ECR
#      repositories first, so the images have somewhere to go
#   5. `scripts/build_push.sh --push` -- every app image pushed as :latest and as
#      the git short SHA, then checked: :latest must exist in all three repos
#   6. `terraform plan -out=tfplan` + `terraform apply tfplan` -- the full stack
#   7. `aws ecs update-service --force-new-deployment` for each service. A new
#      :latest does not change any task definition, so without this ECS keeps
#      running whatever it pulled before
#   8. `aws ecs wait services-stable` -- an apply that returns 0 only means AWS
#      accepted the request, not that the tasks are running and healthy
#   9. prints the outputs the demo needs (API URL, Cognito, dashboard)
#
# FIX: THE PREVIOUS REVISION COULD NOT COMPLETE AN AWS DEPLOYMENT
#   It pushed the images BEFORE Terraform had created the ECR repositories, so
#   build_push.sh skipped every one of them, and after `terraform apply` it ran
#   `kubectl apply -k manifests/` against whatever cluster kubectl pointed at.
#   This project runs on ECS, not EKS: on AWS that step either died for lack of
#   a cluster or applied the manifests to an unrelated local one. The Kubernetes
#   manifests belong to ./scripts/deploy-k3d.sh; this script never calls kubectl.
#
# WHY THERE IS NO `|| true` ANYWHERE
#   An earlier revision appended `|| true` to every `kubectl apply` and then
#   printed "[SUCCESS]" unconditionally, so a total failure still reported
#   success. Every command below is checked; the script exits non-zero on the
#   first hard failure and says which step failed.
#
# USAGE
#   ./scripts/deploy.sh                      # checks + full plan, applies nothing
#   AUTO_APPROVE=true ./scripts/deploy.sh    # full deploy, no prompt
#   ./scripts/deploy.sh --static-only        # rehearsal: no AWS call, no spend
#   IMAGE_TAG=v1.2.0 AUTO_APPROVE=true ./scripts/deploy.sh   # own build tag
#
# EXIT: 0 on success, 1 on the first hard failure, 2 on bad usage.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
# Empty = read var.aws_region from Terraform (terraform.tfvars or the default).
REGION="${REGION:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
STATIC_ONLY=0
# The three images ECS runs; must match local.app_images in terraform/ecr.tf.
APP_COMPONENTS=(api-gateway inventory-app billing-app)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --static-only) STATIC_ONLY=1 ;;
    -h|--help)     sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

STEP=0
WARN_COUNT=0
die()  { echo "[FATAL] $*" >&2; exit 1; }
warn() { echo "  [WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
step() { STEP=$((STEP + 1)); echo; echo "------------------------------------------------------------"
         echo ">>> Step ${STEP}: $*"; echo "------------------------------------------------------------"; }
tf()   { terraform -chdir="$TF_DIR" "$@"; }

echo "============================================================"
echo " Cloud-Design Deployment Automation (AWS, ECS on Fargate)  "
echo "============================================================"
echo " mode        : $([ "${STATIC_ONLY}" -eq 1 ] && echo 'STATIC REHEARSAL (no AWS call, deploys nothing)' || echo 'LIVE')"
echo " region      : ${REGION:-<from terraform var.aws_region>}"
echo " auto-approve: ${AUTO_APPROVE}"
echo "============================================================"

# -----------------------------------------------------------------------------
# Preflight. HARD FAIL: an early revision only printed [WARN] and carried on to
# print [SUCCESS] at the end.
# -----------------------------------------------------------------------------
step "Preflight: prerequisites"
MISSING=""
if [ "${STATIC_ONLY}" -eq 1 ]; then
  REQUIRED=(docker)
  OPTIONAL=(terraform aws jq)
else
  REQUIRED=(aws terraform docker jq)
  OPTIONAL=()
fi
for c in "${REQUIRED[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [ok]   $c -> $(command -v "$c")"
  else
    MISSING+="$c "
  fi
done
for c in ${OPTIONAL[@]+"${OPTIONAL[@]}"}; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [ok]   $c -> $(command -v "$c")"
  else
    echo "  [skip] $c not installed -- acceptable in --static-only mode"
  fi
done

if [ -n "${MISSING}" ]; then
  echo
  echo "[FATAL] missing required prerequisite(s): ${MISSING}" >&2
  echo "        A live deploy needs aws (identity, ECR, ECS), terraform (the" >&2
  echo "        whole stack), docker (to build the images) and jq (to read the" >&2
  echo "        CLI's JSON output)." >&2
  echo >&2
  echo "        To rehearse without touching AWS:" >&2
  echo "            ./scripts/deploy.sh --static-only" >&2
  echo "        To run the Kubernetes manifests on a local k3d cluster instead:" >&2
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
# --static-only: everything that needs no AWS account, then stop.
# -----------------------------------------------------------------------------
if [ "${STATIC_ONLY}" -eq 1 ]; then
  step "Build one image locally (no push)"
  bash "$ROOT_DIR/scripts/build_push.sh" --component api-gateway \
    || die "scripts/build_push.sh failed"
  echo "  [ok]   api-gateway image builds"

  if command -v terraform >/dev/null 2>&1; then
    step "Terraform: init / validate / fmt -check (no AWS credentials needed)"
    tf init -input=false >/dev/null || die "terraform init failed"
    echo "  [ok]   providers installed"
    tf validate || die "terraform validate failed"
    if tf fmt -check -recursive >/dev/null 2>&1; then
      echo "  [ok]   formatting is clean"
    else
      warn "formatting drift; run: terraform -chdir=terraform fmt -recursive"
    fi
    echo "  [--]   terraform plan is NOT run: it reads the account and needs credentials."
  else
    step "Terraform (skipped: not installed)"
  fi

  echo
  echo "============================================================"
  echo " [OK] REHEARSAL COMPLETE -- nothing was deployed and no AWS"
  echo "      API was called. Warnings: ${WARN_COUNT}"
  echo "============================================================"
  echo " Real deploy:  AUTO_APPROVE=true ./scripts/deploy.sh"
  exit 0
fi

# -----------------------------------------------------------------------------
# Identity first. Cheap, and it prevents applying into the wrong account. STS
# answers in every region, so the region does not matter yet.
# -----------------------------------------------------------------------------
step "Identity: aws sts get-caller-identity"
CALLER="$(aws sts get-caller-identity --region "${REGION:-us-east-1}" --output json 2>&1)"
RC=$?
echo "${CALLER}"
if [ "${RC}" -ne 0 ]; then
  die "aws sts get-caller-identity failed (exit ${RC}).
       Run 'aws configure' or export AWS_PROFILE. Refusing to deploy with unknown credentials."
fi
CALLER_ARN="$(printf '%s' "${CALLER}" | jq -r '.Arn')"
CALLER_ID="$(printf '%s' "${CALLER}" | jq -r '.Account')"
echo "  [ok]   deploying as ${CALLER_ARN} (account ${CALLER_ID})"

# -----------------------------------------------------------------------------
# Terraform checks, and the region the stack really goes to.
# -----------------------------------------------------------------------------
step "Terraform: init / validate / fmt -check"
tf init -input=false || die "terraform init failed"
echo "  [ok]   providers installed"
tf validate || die "terraform validate failed -- refusing to plan invalid IaC"
echo "  [ok]   configuration is valid"
if tf fmt -check -recursive >/dev/null 2>&1; then
  echo "  [ok]   formatting is clean"
else
  warn "formatting drift; run: terraform -chdir=terraform fmt -recursive"
fi

# The aws CLI calls below and build_push.sh must use the region the provider
# uses, or the push lands in another region's (non-existent) ECR.
TF_REGION="$(echo 'var.aws_region' | tf console 2>/dev/null | tr -d '"[:space:]')"
[ -n "${TF_REGION}" ] || die "could not read var.aws_region with 'terraform console'"
if [ -n "${REGION}" ] && [ "${REGION}" != "${TF_REGION}" ]; then
  die "REGION=${REGION} but Terraform deploys to ${TF_REGION} (var.aws_region). Unset REGION or change aws_region in terraform.tfvars."
fi
REGION="${TF_REGION}"
echo "  [ok]   region: ${REGION} (var.aws_region)"

if [ "${AUTO_APPROVE}" != "true" ]; then
  step "Terraform: plan (review only, nothing is applied)"
  tf plan -input=false || die "terraform plan failed"
  echo
  echo "============================================================"
  echo " [--] AUTO_APPROVE is not 'true': nothing was created."
  echo "      The plan above is the whole stack; it provisions billable"
  echo "      resources in ${REGION}. To deploy it, re-run:"
  echo "          AUTO_APPROVE=true ./scripts/deploy.sh"
  echo "      Do not apply a plan by hand instead: the images have to be"
  echo "      pushed between the ECR step and the full apply."
  echo "============================================================"
  exit 0
fi

# -----------------------------------------------------------------------------
# ECR first: build_push.sh pushes into these repositories.
# -----------------------------------------------------------------------------
step "Terraform: ECR repositories first (apply -target=aws_ecr_repository.app)"
echo "  Terraform warns that -target is for exceptional cases; this is one, and"
echo "  the full apply two steps later brings the rest of the stack in line."
tf apply -input=false -auto-approve -target=aws_ecr_repository.app \
  || die "terraform apply of the ECR repositories failed"
echo "  [ok]   ECR repositories exist"

step "Build and push the images (scripts/build_push.sh --push)"
REGION="${REGION}" NEXT_HINT=0 bash "$ROOT_DIR/scripts/build_push.sh" --push \
  || die "scripts/build_push.sh failed -- refusing to deploy with no (or stale) images"
# build_push.sh only WARNs when it cannot see a repository, so check the result.
for c in "${APP_COMPONENTS[@]}"; do
  aws ecr describe-images --region "${REGION}" --repository-name "cloud-design/${c}" \
    --image-ids imageTag=latest >/dev/null 2>&1 \
    || die "cloud-design/${c}:latest is not in ECR (${REGION}) after the push; see the build_push.sh output above"
  echo "  [ok]   cloud-design/${c}:latest is in ECR"
done

# -----------------------------------------------------------------------------
# The full stack. A fresh plan: the -target apply above changed the state, so
# any plan saved before it would be stale.
# -----------------------------------------------------------------------------
step "Terraform: plan the full stack"
tf plan -input=false -out=tfplan || die "terraform plan failed"

step "Terraform: apply"
echo "  This provisions billable resources in ${REGION}."
tf apply -input=false tfplan || die "terraform apply failed"
# A saved plan can only be applied once; remove it so nobody tries again.
rm -f "$TF_DIR/tfplan"
echo "  [ok]   infrastructure applied"

# -----------------------------------------------------------------------------
# Roll the services onto the pushed images and wait until they are healthy.
# -----------------------------------------------------------------------------
step "ECS: force a new deployment of each service"
CLUSTER="$(tf output -raw ecs_cluster_name)" || die "terraform output ecs_cluster_name failed"
SERVICES_JSON="$(tf output -json ecs_service_names)" || die "terraform output ecs_service_names failed"
SERVICES=()
while IFS= read -r s; do
  [ -n "$s" ] && SERVICES+=("$s")
done < <(printf '%s' "${SERVICES_JSON}" | jq -r '.[]')
[ "${#SERVICES[@]}" -gt 0 ] || die "terraform output ecs_service_names is empty"

# The task definitions pull var.image_tag. build_push.sh always pushes :latest,
# so any other value means the services may not run the build just pushed.
IMAGE_URLS="$(tf output -json ecr_repository_urls 2>/dev/null)"
for u in $(printf '%s' "${IMAGE_URLS}" | jq -r '.[]' 2>/dev/null); do
  t="${u##*:}"
  if [ "$t" = "latest" ]; then
    echo "  [ok]   task definition pulls ${u##*/}"
  else
    warn "task definition pulls ${u##*/} (var.image_tag = ${t}), not :latest. Check that this is the tag build_push.sh printed above."
  fi
done

for svc in "${SERVICES[@]}"; do
  aws ecs update-service --region "${REGION}" --cluster "${CLUSTER}" --service "${svc}" \
    --force-new-deployment >/dev/null \
    || die "aws ecs update-service --force-new-deployment failed for ${svc}"
  echo "  [ok]   new deployment started: ${svc}"
done

step "ECS: aws ecs wait services-stable"
echo "  Polls every 15 s for up to 10 minutes until each service has one deployment"
echo "  and runningCount == desiredCount."
if ! aws ecs wait services-stable --region "${REGION}" --cluster "${CLUSTER}" --services "${SERVICES[@]}"; then
  echo >&2
  echo "[FATAL] the ECS services did not become stable. Latest events per service:" >&2
  aws ecs describe-services --region "${REGION}" --cluster "${CLUSTER}" --services "${SERVICES[@]}" \
    --output json 2>&1 \
    | jq -r '.services[] | "  \(.serviceName) running=\(.runningCount)/\(.desiredCount):", (.events[:5][] | "    \(.createdAt)  \(.message)")' >&2
  echo "        Usual causes: the image is missing (CannotPullContainerError), the" >&2
  echo "        container exits on start (see its CloudWatch log group), or the ALB" >&2
  echo "        health check on /health fails. If it was only slow, wait again:" >&2
  echo "            aws ecs wait services-stable --region ${REGION} --cluster ${CLUSTER} --services ${SERVICES[*]}" >&2
  exit 1
fi
echo "  [ok]   all ${#SERVICES[@]} services are stable"
aws ecs describe-services --region "${REGION}" --cluster "${CLUSTER}" --services "${SERVICES[@]}" \
  --query 'services[].[serviceName,desiredCount,runningCount,taskDefinition]' --output table \
  || warn "could not print the service table"

# -----------------------------------------------------------------------------
step "Outputs"
# cognito_demo_user_password is sensitive and deliberately not printed here; see
# "Obtain a JWT" in README.md.
for o in api_gateway_invoke_url app_base_url billing_orders_url cognito_hosted_ui_url \
         cognito_demo_client_id cognito_demo_user_email cloudwatch_dashboard_name alb_dns_name; do
  printf '  %-26s %s\n' "$o" "$(tf output -raw "$o" 2>/dev/null || echo '<not set>')"
done

echo
echo "============================================================"
if [ "${WARN_COUNT}" -gt 0 ]; then
  echo " [OK] Deployed to ${REGION}, with ${WARN_COUNT} warning(s) above."
else
  echo " [OK] Deployed to ${REGION}. All ${#SERVICES[@]} ECS services are stable."
fi
echo "============================================================"
echo " Next:"
echo "   README.md, 'Obtain a JWT', to call the protected API"
echo "   ./scripts/run-audit-checks.sh    # live checks"
echo "   ./scripts/destroy.sh             # when the demo is over: it is billed by the hour"
exit 0
