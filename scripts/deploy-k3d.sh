#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design - deploy to a LOCAL k3d cluster (no AWS account required)
# ==============================================================================
# WHY THIS EXISTS
#   The AWS path in scripts/deploy.sh needs a *deployed account* (`aws sts
#   get-caller-identity`), which this environment does not have, so it cannot be
#   demonstrated here. `aws` and `terraform` themselves ARE installed and
#   `terraform validate` passes - what is missing is credentials, not binaries.
#   A local k3d cluster CAN be demonstrated, and it is the only orchestrator in
#   this repository that an examiner can actually watch converge. This script
#   deploys the real manifests/ to a real cluster, for real.
#
# WHAT IT DOES
#   0. checks k3d / kubectl / docker, hard-fails on anything missing
#   1. creates the cluster if it is missing (with metrics-server, which the HPAs
#      require -- without it every HPA reports <unknown> and silently never scales)
#   2. builds the six images locally
#   3. imports them into the cluster (k3d image import) so the kubelet can pull
#      them without a registry
#   4. applies manifests with `kubectl apply -k manifests/` (NEVER -f)
#   5. injects a real Secret, because manifests/secrets.yaml ships REPLACE_ME_*
#      placeholders -- and then NEVER re-applies it (re-applying silently reverts
#      real credentials, which is documented at length in that file's header)
#   6. waits for every rollout to become available
#
# USAGE
#   ./scripts/deploy-k3d.sh                  # create cluster if needed, deploy
#   ./scripts/deploy-k3d.sh --cluster demo   # use a different cluster name
#   ./scripts/deploy-k3d.sh --reuse          # do not create a cluster; use the current context
#   ./scripts/deploy-k3d.sh --recreate       # delete and recreate the cluster first
#   ./scripts/deploy-k3d.sh --dry-run        # validate + server dry-run, deploy nothing
#
# EXIT: 0 on success, 1 on the first hard failure.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAN_DIR="$ROOT_DIR/manifests"

CLUSTER_NAME="${CLUSTER_NAME:-cd-audit}"
NAMESPACE="${NAMESPACE:-cloud-design}"
K3D="${K3D:-$HOME/.local/bin/k3d}"
REUSE=0; RECREATE=0; DRY_RUN=0; ROLL_TIMEOUT="${ROLL_TIMEOUT:-300s}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster)  CLUSTER_NAME="${2:-}"; shift ;;
    --reuse)    REUSE=1 ;;
    --recreate) RECREATE=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -x "${K3D}" ] || K3D="$(command -v k3d 2>/dev/null)"
die()  { echo "[FATAL] $*" >&2; exit 1; }
step() { echo; echo "------------------------------------------------------------"
         echo ">>> $*"; echo "------------------------------------------------------------"; }

echo "============================================================"
echo " cloud-design -> local k3d deployment                      "
echo "============================================================"
echo " cluster   : ${CLUSTER_NAME}"
echo " namespace : ${NAMESPACE}"
echo " mode      : $([ "${DRY_RUN}" -eq 1 ] && echo 'DRY RUN (deploys nothing)' || echo 'LIVE')"
echo "============================================================"

# -----------------------------------------------------------------------------
step "Step 0: prerequisites"
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
echo "  [ok]   kubectl -> $(kubectl version --client 2>/dev/null | head -1)"
command -v docker   >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "the docker daemon is not reachable. Start Docker Desktop first."
echo "  [ok]   docker daemon reachable"
if [ -n "${K3D}" ] && [ -x "${K3D}" ]; then
  echo "  [ok]   k3d -> $(${K3D} version 2>/dev/null | head -1)"
else
  echo "  [--]   k3d not found; --reuse is required and the current kubectl context must already point at a cluster"
  REUSE=1
fi

if [ ! -f "$MAN_DIR/kustomization.yaml" ]; then
  die "manifests/kustomization.yaml is missing.
     'kubectl apply -f manifests/' cannot be used instead: it parses this file
     as a manifest (exit 1) and applies the other files alphabetically, which
     creates api-gateway before namespace."
fi
echo "  [ok]   manifests/kustomization.yaml present (we will use -k)"

# -----------------------------------------------------------------------------
step "Step 1: the cluster"
# -----------------------------------------------------------------------------
CTX_NOW="$(kubectl config current-context 2>/dev/null)"
CLUSTER_EXISTS=0
if [ -n "${K3D}" ] && [ -x "${K3D}" ]; then
  ${K3D} cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${CLUSTER_NAME}" && CLUSTER_EXISTS=1
fi
echo "  current kubectl context: ${CTX_NOW:-<none>}"
echo "  k3d cluster '${CLUSTER_NAME}' exists: $([ "${CLUSTER_EXISTS}" -eq 1 ] && echo yes || echo no)"

if [ "${RECREATE}" -eq 1 ] && [ "${CLUSTER_EXISTS}" -eq 1 ]; then
  step "Step 1a: recreating cluster ${CLUSTER_NAME}"
  ${K3D} cluster delete "${CLUSTER_NAME}" || die "k3d cluster delete failed"
  CLUSTER_EXISTS=0
  echo "  [ok]   cluster deleted"
fi

if [ "${CLUSTER_EXISTS}" -eq 0 ] && [ "${REUSE}" -eq 0 ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  [--]   DRY RUN: not creating the cluster '${CLUSTER_NAME}'"
  else
    step "Step 1b: creating k3d cluster ${CLUSTER_NAME} with metrics-server"
    # --servers 3 gives the HPAs somewhere to scale to. metrics-server is
    # mandatory: an HPA without it reports <unknown> scaling active=false and
    # silently never scales, which is the worst possible failure mode for a
    # "we auto-scale" claim (documented in manifests/api-gateway.yaml).
    #
    # The `@server:*` suffix on --k3s-arg is a node filter and is REQUIRED from
    # k3d v5.7: a bare --k3s-arg that would apply to more than one node is
    # rejected with "K3sExtraArg ... lacks a node filter, but there's more than
    # one node", so cluster creation dies before it starts. It targets every
    # server node (all of which run the apiserver, so they must agree on
    # service-node-port-range).
    ${K3D} cluster create "${CLUSTER_NAME}" \
      --servers 3 \
      --kubeconfig-update-default \
      --k3s-arg '--kube-apiserver-arg=service-node-port-range=30000-32767@server:*' \
      || die "k3d cluster create failed"
    echo "  [ok]   cluster created"

    echo "  [..]   installing metrics-server (required by the HPAs)"
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml \
      || die "metrics-server install failed -- the HPAs would silently never scale"
    kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s \
      || echo "  [WARN] metrics-server did not become ready in time; HPAs may report <unknown>"
    echo "  [ok]   metrics-server installed"
  fi
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "kubectl still cannot reach a cluster after the cluster step.
       Check: kubectl config get-contexts ; kubectl config use-context k3d-${CLUSTER_NAME}"
fi
echo "  [ok]   cluster reachable: $(kubectl config current-context 2>/dev/null)"

# -----------------------------------------------------------------------------
step "Step 2: build the six images"
# -----------------------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "  [--]   DRY RUN: not building images"
else
  bash "$ROOT_DIR/scripts/build_push.sh" \
    || die "scripts/build_push.sh failed -- not importing images into the cluster"
  echo "  [ok]   images built"
fi

# -----------------------------------------------------------------------------
step "Step 3: import images into the cluster"
# -----------------------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "  [--]   DRY RUN: not importing images"
else
  IMAGES=()
  # IMAGE NAME DRIFT, made explicit. The build produces one image per srcs/
  # DIRECTORY (cloud-design/api-gateway-app, cloud-design/rabbit-queue), while
  # the manifests reference the SERVICE names used on AWS
  # (cloud-design/api-gateway, cloud-design/rabbitmq). Two of the six differ, so
  # tagging by directory name silently produces an image the kubelet never asks
  # for and the pod sits in ImagePullBackOff forever.
  #   srcs directory        manifest image name
  alias_image_name() {
    case "$1" in
      api-gateway-app) echo "api-gateway"   ;;
      rabbit-queue)     echo "rabbitmq"      ;;
      *)                echo "$1"            ;;
    esac
  }
  for d in "$ROOT_DIR"/srcs/*/; do
    [ -d "$d" ] || continue
    c="$(basename "$d")"
    # The manifests reference the ':latest' tag with imagePullPolicy IfNotPresent,
    # so that is the tag that must exist on the node.
    if docker image inspect "cloud-design/${c}:local" >/dev/null 2>&1; then
      name="$(alias_image_name "${c}")"
      docker tag "cloud-design/${c}:local" "cloud-design/${name}:latest"
      IMAGES+=("cloud-design/${name}:latest")
    else
      die "cloud-design/${c}:local is missing; run ./scripts/build_push.sh first"
    fi
  done

  # Guard: every image the manifests actually reference must now exist locally.
  # Without this the failure surfaces much later as ImagePullBackOff, which looks
  # like a cluster problem instead of a naming one.
  MISSING_IMG=()
  while read -r ref; do
    [ -n "${ref}" ] || continue
    docker image inspect "${ref}" >/dev/null 2>&1 || MISSING_IMG+=("${ref}")
  done <<EOF
$(grep -rhoE 'image:[[:space:]]*cloud-design/[a-z0-9-]+:latest' "${MAN_DIR}"/*.yaml 2>/dev/null \
   | sed -E 's/image:[[:space:]]*//' | sort -u)
EOF
  if [ "${#MISSING_IMG[@]}" -gt 0 ]; then
    die "the manifests reference image(s) that do not exist locally: ${MISSING_IMG[*]} -- fix the mapping in Step 3 of this script"
  fi
  echo "  [ok]   every image referenced by manifests/ exists locally"

  echo "  importing ${#IMAGES[@]} image(s): ${IMAGES[*]}"
  # `-c/--cluster` is REQUIRED and must be a FLAG. In k3d v5.9 the positional
  # cluster argument is silently ignored, so `k3d image import cd-audit img:tag`
  # falls back to the built-in default and fails with
  #   "failed to get cluster k3s-default: No nodes found for given cluster"
  # even though cd-audit exists and is running. Verified against v5.9.0.
  ${K3D} image import -c "${CLUSTER_NAME}" "${IMAGES[@]}" \
    || die "k3d image import failed -- pods would fall back to imagePullBackOff"
  echo "  [ok]   images imported into the cluster"
fi

# -----------------------------------------------------------------------------
step "Step 4: apply the manifests with -k"
# -----------------------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  OBJ="$(kubectl kustomize "$MAN_DIR" 2>/dev/null | grep -c '^kind:' | head -1)"
  echo "  [--]   DRY RUN: kustomize parses (${OBJ} objects); running a server dry-run"
  if kubectl apply --dry-run=server -k "$MAN_DIR" >/dev/null 2>&1; then
    echo "  [ok]   server dry-run accepted. Nothing was applied."
  else
    kubectl apply --dry-run=server -k "$MAN_DIR" 2>&1 | tail -20
    die "server dry-run was rejected by the API server"
  fi
  echo
  echo "============================================================"
  echo " [OK] DRY RUN COMPLETE -- nothing was created.               "
  echo "============================================================"
  exit 0
fi

APPLY_OUT="$(kubectl apply -k "$MAN_DIR" 2>&1)"
RC=$?
echo "${APPLY_OUT}"
[ "${RC}" -eq 0 ] || die "'kubectl apply -k manifests/' failed with exit ${RC}.
       The previous revision of this script appended '|| true' to every apply and
       then printed [SUCCESS] regardless. The real error is above."

# -----------------------------------------------------------------------------
step "Step 5: inject a working Secret"
# -----------------------------------------------------------------------------
# manifests/secrets.yaml deliberately contains REPLACE_ME_* placeholders. This
# writes real values from OUTSIDE the repo so nothing in git ever changes.
# THIS MUST NOT BE REPEATED AFTER A LATER `kubectl apply -k manifests/` -- that
# would silently revert the Secret to the placeholders. See the header of
# manifests/secrets.yaml for the full explanation.
if [ -f "$ROOT_DIR/.env" ]; then
  set -a; . "$ROOT_DIR/.env"; set +a
  echo "  [ok]   credentials loaded from .env"
else
  echo "  [WARN] no .env found. Generate one with: make env"
  echo "         Without it the apps will CrashLoopBackOff on REPLACE_ME_* credentials."
  set -a; [ -f "$ROOT_DIR/.env.example" ] && . "$ROOT_DIR/.env.example"; set +a
  echo "  [--]   falling back to the non-secret placeholder values in .env.example"
fi

kubectl create secret generic cloud-design-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=INVENTORY_DB_USER="${INVENTORY_DB_USER}" \
  --from-literal=INVENTORY_DB_PASSWORD="${INVENTORY_DB_PASSWORD}" \
  --from-literal=BILLING_DB_USER="${BILLING_DB_USER}" \
  --from-literal=BILLING_DB_PASSWORD="${BILLING_DB_PASSWORD}" \
  --from-literal=RABBITMQ_USER="${RABBITMQ_USER}" \
  --from-literal=RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "could not create/overwrite the cloud-design-secrets Secret"
echo "  [ok]   Secret cloud-design-secrets written from outside the repo"
echo "  [!]    do NOT re-run 'kubectl apply -k manifests/' without re-running this"
echo "         step -- it reverts the Secret to the REPLACE_ME_* placeholders."

# -----------------------------------------------------------------------------
step "Step 6: wait for rollouts"
# -----------------------------------------------------------------------------
# envFrom/secretKeyRef values are resolved when a container STARTS, so pods that
# already started with the placeholders keep them until restarted.
echo "  restarting workloads so they pick up the real Secret values"
for d in $(kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null); do
  kubectl rollout restart -n "${NAMESPACE}" "$d" >/dev/null 2>&1 && echo "    restarted ${d}"
done
for s in $(kubectl get statefulset -n "${NAMESPACE}" -o name 2>/dev/null); do
  kubectl rollout restart -n "${NAMESPACE}" "$s" >/dev/null 2>&1 && echo "    restarted ${s}"
done

FAILED=0
for d in $(kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null); do
  printf '  deployment/%-30s ' "${d#deployment.apps/}"
  if kubectl wait --for=condition=available -n "${NAMESPACE}" "$d" --timeout="${ROLL_TIMEOUT}" >/dev/null 2>&1; then
    echo "available"
  else
    echo "NOT available in ${ROLL_TIMEOUT}"; FAILED=$((FAILED + 1))
  fi
done
for s in $(kubectl get statefulset -n "${NAMESPACE}" -o name 2>/dev/null); do
  printf '  statefulset/%-30s ' "${s#statefulset.apps/}"
  if kubectl rollout status -n "${NAMESPACE}" "$s" --timeout="${ROLL_TIMEOUT}" >/dev/null 2>&1; then
    echo "rolled out"
  else
    echo "NOT rolled out in ${ROLL_TIMEOUT}"; FAILED=$((FAILED + 1))
  fi
done

if [ "${FAILED}" -gt 0 ]; then
  echo
  kubectl get pods -n "${NAMESPACE}" -o wide 2>&1
  echo >&2
  echo "[FATAL] ${FAILED} workload(s) did not converge." >&2
  echo "        Most common cause: the REPLACE_ME_* Secret, or the image" >&2
  echo "        'cloud-design/<c>:latest' not being present on the node." >&2
  echo "        Diagnostics:" >&2
  echo "            kubectl describe pod -n ${NAMESPACE} <pod>" >&2
  echo "            kubectl logs -n ${NAMESPACE} -l app=inventory-app --tail=40" >&2
  exit 1
fi

echo
kubectl get pods -n "${NAMESPACE}" -o wide 2>&1
echo
kubectl get hpa -n "${NAMESPACE}" 2>&1
echo
echo "============================================================"
echo " [OK] Deployed to k3d cluster '${CLUSTER_NAME}'.              "
echo "============================================================"
echo " Port-forward the gateway to try it:"
echo "     kubectl port-forward -n ${NAMESPACE} svc/api-gateway-service 3000:3000"
echo "     curl -s http://localhost:3000/health"
echo
echo " Prove the audit claims:"
echo "     ./scripts/run-audit-checks.sh"
echo " Tear it down with:  ./scripts/destroy.sh --k3d"
exit 0