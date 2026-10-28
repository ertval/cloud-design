#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design - build every microservice image, optionally push to ECR
# ==============================================================================
# WHAT THIS DOES
#   1. builds srcs/<component>/Dockerfile for all six components
#   2. tags each image  cloud-design/<component>:local  (the tag docker-compose.yml
#      and deploy-k3d.sh use)
#   3. verifies the image actually exists afterwards (a build that printed no
#      error but produced nothing is still a failure)
#   4. with PUSH=1, logs into ECR and pushes each application image under TWO
#      tags: :latest, which the ECS task definitions pull by default
#      (var.image_tag in terraform/variables.tf), and an immutable build tag,
#      the git short SHA of the sources, which can be pinned with
#      `terraform apply -var image_tag=<tag>`
#   5. prints the final `docker images` table so the real sizes are on record
#
# IT FAILS LOUDLY. No `|| true`, no `set -e`-style silent continuation: the first
# hard failure aborts with a non-zero exit and a message naming the component.
#
# WHY NO COMPILER IS NEEDED  (this is the point of the --only-binary=:all: notes)
#   Every image is either (a) a multi-stage python:3.11-alpine build that installs
#   only the PRE-COMPILED WHEELS from requirements.txt into a clean runtime stage,
#   or (b) a stock official image (postgres:17-alpine, rabbitmq:3.13-*-alpine) with
#   scripts copied in. No image compiles C/C++/Rust from source, so the slim
#   alpine runtimes need no gcc/musl-dev/build-base toolchain -- which is exactly
#   why pip is invoked with --only-binary=:all: in the builder stage. That flag is
#   what keeps the image small AND honest: if a dependency ever lost its wheel,
#   the build would fail loudly instead of silently pulling in a compiler and
#   inflating the image.
#
# USAGE
#   ./scripts/build_push.sh                    # build + tag :local, no push
#   ./scripts/build_push.sh --push             # build, then push to ECR
#   PUSH=1 ./scripts/build_push.sh             # same as --push
#   ./scripts/build_push.sh --no-cache         # no layer cache
#   ./scripts/build_push.sh --component billing-app   # build just one
#   REGION=us-east-1 ACCOUNT=123456789012 ./scripts/build_push.sh --push
#   IMAGE_TAG=v1.2.0 ./scripts/build_push.sh --push    # own build tag, not the SHA
#
# EXIT: 0 all built (and pushed if requested); 1 on the first hard failure.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PUSH="${PUSH:-0}"
NO_CACHE=""
ONLY_COMPONENT=""
REGION="${REGION:-us-east-1}"
ACCOUNT="${ACCOUNT:-}"
IMAGE_PREFIX="${IMAGE_PREFIX:-cloud-design}"
TAG="${TAG:-local}"
# Build tag pushed next to :latest. Empty = derived from git below.
IMAGE_TAG="${IMAGE_TAG:-}"
# 0 = do not print the "Next, move the ECS services ..." hint (deploy.sh does
# those steps itself right after the push).
NEXT_HINT="${NEXT_HINT:-1}"
AWS="${AWS:-aws}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --push)     PUSH=1 ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    --component) ONLY_COMPONENT="${2:-}"; shift ;;
    -h|--help)  sed -n '2,43p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

FAIL_COUNT=0
BUILD_COUNT=0
PUSH_COUNT=0

die() { echo "[FATAL] $*" >&2; exit 1; }
ok()  { echo "[OK]    $*"; }
bad() { echo "[FAIL]  $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "============================================================"
if [ "${PUSH}" = "1" ]; then MODE="build + push"; else MODE="build only"; fi
echo " cloud-design image build (${MODE})"
echo " root=${ROOT_DIR}  tag=${TAG}  prefix=${IMAGE_PREFIX}"
echo "============================================================"

# --- prerequisites: hard-fail, do not warn and continue ---------------------
command -v docker >/dev/null 2>&1 || die "docker is not installed. Install Docker Desktop and re-run."
if ! docker info >/dev/null 2>&1; then
  die "the docker daemon is not reachable ('docker info' failed). Start Docker Desktop and re-run."
fi
ok "docker is installed and the daemon is reachable"

# Enumerate the components from disk so this never drifts from the repo.
COMPONENTS=()
for d in "$ROOT_DIR"/srcs/*/; do
  [ -d "$d" ] || continue
  c="$(basename "$d")"
  [ -n "${ONLY_COMPONENT}" ] && [ "$c" != "${ONLY_COMPONENT}" ] && continue
  COMPONENTS+=("$c")
done
if [ "${#COMPONENTS[@]}" -eq 0 ]; then
  die "no buildable components found under srcs/ (looking for one Dockerfile each)${ONLY_COMPONENT:+ matching '${ONLY_COMPONENT}'}"
fi
echo "components to build (${#COMPONENTS[@]}): ${COMPONENTS[*]}"
echo

# --- ECR tags, only when a push was actually requested ---------------------
# FIX: the push used to send <repo>:${TAG}, i.e. :local, while the ECS task
# definitions pull :latest, so every task failed with CannotPullContainerError.
# The local tag stays :local (docker-compose.yml and deploy-k3d.sh use it); what
# goes to ECR is :latest plus an immutable build tag.
# The build tag is the git short SHA. If srcs/ has uncommitted changes the image
# is not what that commit contains, so the tag gets a -dirty-<UTC time> suffix
# and two dirty builds never share a tag.
PUSH_TAGS=()
if [ "${PUSH}" = "1" ]; then
  if [ -z "${IMAGE_TAG}" ]; then
    IMAGE_TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null)"
    if [ -n "${IMAGE_TAG}" ] && [ -n "$(git -C "$ROOT_DIR" status --porcelain -- srcs 2>/dev/null)" ]; then
      IMAGE_TAG="${IMAGE_TAG}-dirty-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    [ -n "${IMAGE_TAG}" ] || IMAGE_TAG="build-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  # Same rule as the image_tag validation in terraform/variables.tf.
  printf '%s' "${IMAGE_TAG}" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' \
    || die "IMAGE_TAG='${IMAGE_TAG}' is not a valid ECR tag (1-128 of A-Z a-z 0-9 _ . -, not starting with . or -)"
  PUSH_TAGS=(latest)
  [ "${IMAGE_TAG}" != "latest" ] && PUSH_TAGS+=("${IMAGE_TAG}")
  ok "ECR tags to push: ${PUSH_TAGS[*]}"
fi

# --- ECR login, only when a push was actually requested --------------------
ECR_REG=""
if [ "${PUSH}" = "1" ]; then
  command -v "${AWS}" >/dev/null 2>&1 \
    || die "PUSH=1 was requested but the aws CLI ('${AWS}') is not installed. Install it and configure a profile, or drop --push to build locally only."
  ok "aws CLI is present"

  CALLER="$("${AWS}" sts get-caller-identity --output json 2>&1)"
  if [ $? -ne 0 ]; then
    die "aws sts get-caller-identity failed, refusing to guess credentials:
${CALLER}"
  fi
  echo "${CALLER}"
  ACCOUNT_ARN="$(printf '%s' "${CALLER}" | jq -r '.Arn' 2>/dev/null)"
  ACCOUNT="${ACCOUNT:-$(printf '%s' "${CALLER}" | jq -r '.Account' 2>/dev/null)}"
  ok "authenticated as ${ACCOUNT_ARN} (account ${ACCOUNT})"

  ECR_REG="$(terraform -chdir="$ROOT_DIR/terraform" output -raw ecr_registry_url 2>/dev/null)"
  if [ -z "${ECR_REG}" ]; then
    ECR_REG="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
    echo "        (terraform output ecr_registry_url unavailable; using the standard pattern)"
  fi
  ok "target ECR registry: ${ECR_REG}"

  echo "        logging in to ECR ..."
  "${AWS}" ecr get-login-password --region "${REGION}" 2>/dev/null \
    | docker login --username AWS --password-stdin "${ECR_REG}" >/dev/null 2>&1 \
    || die "docker login to ${ECR_REG} failed. Check credentials and that the ECR registry exists."
  ok "docker login to ${ECR_REG} succeeded"
fi

# --- build each image --------------------------------------------------------
for c in "${COMPONENTS[@]}"; do
  df="$ROOT_DIR/srcs/${c}/Dockerfile"
  [ -f "$df" ] || die "srcs/${c}/Dockerfile does not exist"

  # Build context is srcs/<component>, so srcs/<component>/.dockerignore applies
  # (not the repo-root one -- see the scope note at the top of .dockerignore).
  echo "------------------------------------------------------------"
  echo ">>> building ${IMAGE_PREFIX}/${c}:${TAG}   (context: srcs/${c})"
  # shellcheck disable=SC2086
  if docker build ${NO_CACHE} -f "$df" -t "${IMAGE_PREFIX}/${c}:${TAG}" "$ROOT_DIR/srcs/${c}"; then
    ok "built ${IMAGE_PREFIX}/${c}:${TAG}"
    BUILD_COUNT=$((BUILD_COUNT + 1))
  else
    bad "docker build FAILED for srcs/${c} -- aborting"
    exit 1
  fi

  # Verify the image really exists. A zero-exit build that produced no image
  # (e.g. a BuildKit cache-only no-op) must not be counted as success.
  if docker image inspect "${IMAGE_PREFIX}/${c}:${TAG}" >/dev/null 2>&1; then
    sz="$(docker image inspect --format '{{.Size}}' "${IMAGE_PREFIX}/${c}:${TAG}" 2>/dev/null)"
    ok "verified ${IMAGE_PREFIX}/${c}:${TAG} exists (${sz} bytes)"
  else
    bad "build reported success but ${IMAGE_PREFIX}/${c}:${TAG} does not exist"
    exit 1
  fi
done

# --- push, only when requested ----------------------------------------------
if [ "${PUSH}" = "1" ]; then
  echo
  echo "------------------------------------------------------------"
  echo ">>> pushing to ${ECR_REG}"
  # ECR repository names are cloud-design/<component>; see terraform/ecr.tf.
  for c in "${COMPONENTS[@]}"; do
    repo="cloud-design/${c}"
    if "${AWS}" ecr describe-repositories --repository-names "${repo}" --region "${REGION}" >/dev/null 2>&1; then
      # The second push only uploads a manifest: the layers are already there.
      for t in "${PUSH_TAGS[@]}"; do
        remote="${ECR_REG}/${repo}:${t}"
        if docker tag "${IMAGE_PREFIX}/${c}:${TAG}" "${remote}"; then
          if docker push "${remote}"; then
            ok "pushed ${remote}"
          else
            bad "docker push FAILED for ${remote}"
            exit 1
          fi
        else
          bad "docker tag FAILED for ${remote}"
          exit 1
        fi
      done
      PUSH_COUNT=$((PUSH_COUNT + 1))
    else
      echo "[WARN]  ECR repository '${repo}' does not exist in ${REGION}; skipped ${c}."
      echo "        Create it with terraform (aws_ecr_repository only covers the 3 app"
      echo "        images by design -- the databases and the broker run as managed RDS/MQ)."
    fi
  done
fi

# --- final image table -------------------------------------------------------
echo
echo "============================================================"
echo " docker images (real sizes, measured by the daemon)          "
echo "============================================================"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' | head -30
echo
echo " exact sizes for the images this run produced:"
for c in "${COMPONENTS[@]}"; do
  printf '   %-46s %s\n' "${IMAGE_PREFIX}/${c}:${TAG}" \
    "$(docker image inspect --format '{{.Size}}' "${IMAGE_PREFIX}/${c}:${TAG}" 2>/dev/null || echo MISSING)"
done

echo
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
echo "  built : ${BUILD_COUNT}/${#COMPONENTS[@]}"
if [ "${PUSH}" = "1" ]; then echo "  pushed: ${PUSH_COUNT} (tags: ${PUSH_TAGS[*]})"; fi
echo "  failed: ${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo
  echo ">>> BUILD FAILED <<<"
  exit 1
fi
echo
if [ "${PUSH}" = "1" ]; then echo ">>> ALL IMAGES BUILT AND PUSHED <<<"; else echo ">>> ALL IMAGES BUILT <<<"; fi
if [ "${PUSH}" != "1" ]; then
  echo "Next: ./scripts/deploy-k3d.sh   (local cluster)   or   ./scripts/deploy.sh (AWS)"
elif [ "${NEXT_HINT}" != "0" ]; then
  # Pushing a new :latest does not change any task definition, so ECS keeps
  # running the old image until it is told to redeploy.
  echo "Next, move the ECS services onto these images, either:"
  echo "  pin this build (new task definition revision, ECS rolls every service):"
  echo "    terraform -chdir=terraform apply -var image_tag=${IMAGE_TAG}"
  echo "  or stay on :latest and force a redeploy of each service:"
  echo "    aws ecs update-service --cluster \"\$(terraform -chdir=terraform output -raw ecs_cluster_name)\" \\"
  echo "      --service <name from: terraform -chdir=terraform output ecs_service_names> --force-new-deployment"
fi
exit 0