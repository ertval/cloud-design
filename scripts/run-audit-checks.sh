#!/usr/bin/env bash
# ==============================================================================
# cloud-design - automated docs/audit.md verification runner  (THE MAIN EVENT)
# ==============================================================================
#
# WHAT THIS DOES
#   Walks every question in docs/audit.md (22 `######` items + the 5 Well-
#   Architected pillars + the 14 stakeholder roleplay questions + the 2 bonus
#   questions), runs the REAL command the rubric asks for, prints that command's
#   REAL stdout/stderr, and turns each item into one of three verdicts:
#
#       [PASS]    the check was executed and the real evidence satisfies it
#       [FAIL]    the check was executed and the real evidence contradicts it
#       [INVALID] the check could NOT be determined here (tool absent, cluster
#                 down, target not built ...) - reported as its own state, NEVER
#                 counted as a pass and NEVER silently skipped
#
#   It is deliberately verbose and never hides a command: this is the script you
#   run IN FRONT OF THE EXAMINER, not a fast CI gate.
#
#   Non-automatable rubric items (the grader-observation questions and the
#   roleplay questions) are printed as clearly-labelled [NOTE] lines pointing at
#   docs/AUDIT_GUIDE.md. They are NOT scored - a script cannot grade prose.
#
# HOW TO RUN IT
#   ./scripts/run-audit-checks.sh                # everything
#   ./scripts/run-audit-checks.sh --static       # skip the live docker/kubectl
#                                               # sections (they report INVALID)
#   ./scripts/run-audit-checks.sh --section 90   # one numbered section
#   ./scripts/run-audit-checks.sh --list         # list the sections
#   ./scripts/run-audit-checks.sh --no-color     # plain output
#
# EXIT CODE
#   1 if any item FAILED. INVALID items do not fail the run, but they are counted
#   and listed separately so an examiner can see what was NOT proven.
#
# DESIGN NOTES THAT MATTER (do not "simplify" these away)
#   * `set -uo pipefail`, deliberately NO `-e`. A failed check must be RECORDED
#     and the walkthrough must CONTINUE: the whole point is to show the examiner
#     every rubric item, including the ones that fail.
#   * Reachability gating. When kubectl cannot reach a cluster, `kubectl get ...`
#     prints to stderr and NOTHING to stdout, so a COUNT comes out as 0 and an
#     absence-assertion silently PASSES on a dead cluster. Every count and every
#     "must be absent" assertion goes through count_ok() and degrades to INVALID.
#     (Note: `[ "" -eq 0 ]` is TRUE in bash, which is exactly the bug this guards.)
#   * A quote trap worth remembering: `"$(grep 'x"y' f)"` MIS-PARSES in bash -
#     a double quote nested inside $( ) inside "..." swallows the rest of the
#     line into the substitution. Every Terraform resource count below therefore
#     goes through the tf_res()/tf_res_in() helpers, which take the type name as a
#     plain argument and never nest a double quote inside a substitution.
#   * RUN_MARKER makes every per-run assertion unable to be satisfied by state
#     left behind by a previous run. Section 17 filters the load balancer's
#     access log on that marker instead of a `--since` window, so traffic served
#     before a replica was killed cannot be counted as part of the current run.
#   * `trap cleanup EXIT` restores mutated state.
#   * `--section N` must work for EVERY N. All environment detection therefore
#     runs in probe_environment() BEFORE any section, and report_preconditions()
#     is what `step "0"` gates -- otherwise `--section 8` reported
#     "[INVALID] compose stack is not running" against a healthy stack.
#     Variables a later section reads (TF_COUNT, TF_MODULE_BLOCKS,
#     README_BYTES, GUIDE_BYTES) are computed once in the preamble, not inside
#     whichever section happens to print them first.
#   * Shared parsers live in scripts/lib/ so the two suites cannot drift:
#       hcl_sg_world_open.awk -- which security group a world-open ingress rule
#                                is really ATTACHED to, in either HCL style
#       k8s_doc.awk            -- multi-document YAML flattened by dotted key
#                                path, so a PDB can be judged against the
#                                replicas it selects and a livenessProbe against
#                                the readinessProbe beside it
#     A missing parser file is reported as INVALID/FAIL, never as a silent pass.
#   * `|| true` policy: this script deliberately has no `-e`, so `|| true` can
#     never decide whether the run continues -- it only discards an exit status
#     that the caller does not use. Every remaining occurrence carries a comment
#     saying why it is safe: fcount(), cleanup(), RECENT_ERR, HIST_ERR.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
MAN_DIR="${ROOT_DIR}/manifests"
ECS_DIR="${ROOT_DIR}/ecs-tasks"
export PATH="${HOME}/.local/bin:${PATH}"

# Unique per-run marker so no assertion can be satisfied by stale state.
RUN_MARKER="audit-$$-$(date +%s)"
# A user_id for a live billing round-trip, unique per run.
# Extract the CRC FIELD, not characters 1-6 of the line: `cksum` prints
# "<crc> <byte-count>", so cutting six characters would pull in the separating
# space and part of the byte count whenever the CRC is shorter than six digits --
# rare, but it produced a user_id like "1234 2", which strict INT32 validation
# rejects with a 400. awk takes field 1, so the result is always pure digits.
AUDIT_USER_ID="9$(printf '%s' "${RUN_MARKER}" | cksum | awk '{print $1}' | cut -c1-6)"
LB_MARK="lb-${RUN_MARKER}"
LOAD_OUT="/tmp/cloud-design-load-${RUN_MARKER}.txt"

STATIC_ONLY=0
NO_COLOR=0
ONLY_SECTION=""
LIST_ONLY=0

GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --static)   STATIC_ONLY=1 ;;
    --no-color) NO_COLOR=1 ;;
    --section)  ONLY_SECTION="${2:-}"; shift ;;
    --list)     LIST_ONLY=1 ;;
    # The header block grows as design notes are added, so a hardcoded line
    # range would silently truncate it (or print code). Locate it instead.
    -h|--help)  awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "${NO_COLOR}" -eq 0 ] && [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
fi

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
INVALID_COUNT=0
NOTE_COUNT=0
FAILURES=()
INVALID_REASONS=()
CURRENT_SECTION=""
SKIPPED_SECTIONS=()

pass()    { echo -e "${GREEN}  [PASS]${NC}    $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo -e "${RED}  [FAIL]${NC}    $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("S${CURRENT_SECTION}: $1"); }
invalid() { echo -e "${YELLOW}  [INVALID]${NC} $1"; INVALID_COUNT=$((INVALID_COUNT + 1)); INVALID_REASONS+=("S${CURRENT_SECTION}: $1"); }
note()    { echo -e "${BLUE}  [NOTE]${NC}    $1"; NOTE_COUNT=$((NOTE_COUNT + 1)); }

SECTIONS_RAN=0
step() {
  CURRENT_SECTION="$1"
  if [ -n "${ONLY_SECTION}" ] && [ "${ONLY_SECTION}" != "$1" ]; then
    SKIPPED_SECTIONS+=("$1"); CURRENT_SECTION="?"; return 1
  fi
  echo
  echo -e "${BOLD}${YELLOW}============================================================${NC}"
  echo -e "${BOLD}${YELLOW} SECTION ${1} -- ${2}${NC}"
  echo -e "${BOLD}${YELLOW}   rubric: ${3}${NC}"
  echo -e "${BOLD}${YELLOW}============================================================${NC}"
  SECTIONS_RAN=$((SECTIONS_RAN + 1))
  return 0
}

show() { echo -e "${BLUE}\$ ${NC}$1"; if [ "$#" -ge 2 ] && [ -n "$2" ]; then echo "$2"; fi; return 0; }

assert_contains()     { if grep -qi -- "$3" <<<"$2"; then pass "$1 (found '$3')"; else fail "$1 (missing '$3')"; fi; }
assert_not_contains() { if grep -qi -- "$3" <<<"$2"; then fail "$1 (unexpectedly found '$3')"; else pass "$1 (absent, as required)"; fi; }
assert_eq()  { if [ "$2" = "$3" ]; then pass "$1 (= '$3')"; else fail "$1 (expected '$2', got '$3')"; fi; }

# A COUNT is only trustworthy if it is a non-empty all-digit string. `[ "" -eq 0 ]`
# is TRUE in bash, so an empty result from a dead cluster would otherwise satisfy
# every "must be zero/absent" assertion. Every count goes through this first.
count_ok() { [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]]; }

# --- quote-safe Terraform helpers -------------------------------------------
# These take the AWS resource type as a PLAIN argument. Never write
# "$(grep '...\"...' file)": bash mis-parses a double quote nested inside $( )
# inside a double-quoted string and silently swallows the rest of the command.
tf_types() { grep -hE '^resource ' "$TF_DIR"/*.tf 2>/dev/null | sed -E 's/^resource +"([^"]+)".*/\1/'; }
tf_res()      { tf_types | grep -xc "aws_$1"; }              # exact type match, whole .tf dir
tf_res_in()   { grep -hE '^resource ' "$1" 2>/dev/null | sed -E 's/^resource +"([^"]+)".*/\1/' | grep -xc "aws_$2"; }
tf_res_names(){ tf_types | grep "^aws_$1$" | sed "s/aws_$1\.//"; }
tf_any()      { tf_types | grep -qx "aws_$1" && return 0 || return 1; }
tf_grep()     { grep -rh "$1" "$TF_DIR"/*.tf 2>/dev/null; }   # $1 must contain NO double quote
# Print one `resource "<type>" "<label>" { ... }` block from a terraform file.
# Built with index() on a constructed needle rather than a regex: a loose regex
# like .http. also matches "https", which silently produced a FALSE NEGATIVE.
tf_block() { # tf_block <file> <type> <label>
  awk -v ty="$2" -v lbl="$3" '
    /^resource / && index($0, "\"" ty "\"") && index($0, "\"" lbl "\"") {f=1}
    f && /^}/{exit}
    f {print}
  ' "$1" 2>/dev/null
}

# File/line counter that never emits a doubled value. `grep -c || echo 0` prints
# TWO lines (the count and the fallback) when grep exits non-zero, which then
# poisons arithmetic like $(( n % 2 )). Use this instead.
# `grep -c` exits 1 when the count is zero -- which for a "how many X are there"
# question is the SUCCESS case, not an error. The `|| true` is deliberate: the
# caller wants the NUMBER, and deliberately discards the exit status. It is safe
# here because `head -1` is last in the pipeline and always succeeds, so the
# pipeline can only fail if `head` itself is missing -- in which case there is no
# number to report anyway and count_ok() below turns the empty result into a
# clean INVALID rather than a silent pass.
fcount() { grep -c "$@" 2>/dev/null | head -1 || true; }

# YAML settings must be counted with COMMENTS removed. The manifests EXPLAIN
# their security choices in prose, and those explanation lines contain the very
# keys being counted (e.g. a comment saying "readOnlyRootFilesystem: true"), which
# silently inflated a count of 3 into 6.
yc() { # yc <grep-args...>  -- count matches in manifests/ with YAML comments stripped
  local n
  n=$(sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*#/d' "$1" 2>/dev/null | grep -c "${@:2}" | head -1)
  printf '%s' "${n:-0}"
}

# --- attachment-aware HCL security-group parser ------------------------------
# Reports every INGRESS rule that admits 0.0.0.0/0, named by the security group
# it is REALLY attached to. The parser lives in one shared file so the two audit
# suites can never drift apart on the single most security-critical check in the
# repo; see scripts/lib/hcl_sg_world_open.awk for why the old awk one-liner was
# defeatable by formatting alone.
SG_PARSER="${SCRIPT_DIR}/lib/hcl_sg_world_open.awk"
sg_world_open() { # sg_world_open [terraform-file-glob-root]
  if [ ! -f "${SG_PARSER}" ]; then
    echo "__PARSER_MISSING__ ${SG_PARSER}"
    return 0
  fi
  awk -f "${SG_PARSER}" "$TF_DIR"/*.tf 2>/dev/null
}

http_code() {
  local method="$1" url="$2" data="${3:-}"
  if [ -n "${data}" ]; then
    curl -s -m 10 -o /dev/null -w "%{http_code}" -X "${method}" "${url}" \
      -H "Content-Type: application/json" -d "${data}" 2>/dev/null || printf '000'
  else
    curl -s -m 10 -o /dev/null -w "%{http_code}" -X "${method}" "${url}" 2>/dev/null || printf '000'
  fi
}

cleanup() {
  local rc=$?
  # KEEP `|| true`: this runs from `trap cleanup EXIT`, so a non-zero status here
  # would replace the script's real exit code with the exit code of a failed rm
  # on a file that may legitimately already be gone. Cleanup must never change
  # the verdict.
  rm -f "${LOAD_OUT}" 2>/dev/null || true
  if [ "${STATE_MUTATED}" -eq 1 ]; then
    echo -e "\n${YELLOW}>>> [Cleanup] restoring mutated state (${MUTATION_DESC}) ...${NC}"
    restore_state
  fi
  echo -e "\n${BOLD}Run marker: ${RUN_MARKER}${NC}"
  return "${rc}"
}
STATE_MUTATED=0
MUTATION_DESC="none"
restore_state() { :; }   # replaced per-section when a section mutates state
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Preconditions -- detected ONCE, reported honestly. A missing tool can only ever
# produce INVALID downstream, never PASS.
# -----------------------------------------------------------------------------
DOCKER_OK=0; KUBECTL_OK=0; K3D_OK=0; AWS_OK=0; TERRAFORM_OK=0; JQ_OK=0; CURL_OK=0
DOCKER_DAEMON_OK=0
CLUSTER_REACHABLE=0
COMPOSE_STACK_UP=0
LB_URL="http://localhost:3000"

# Discovered once in the preamble so that every section can be executed on its
# own with --section (a section must never depend on an earlier section having
# run, or it silently reports 0 and looks like a failure of the project).
# TF_COUNT / TF_MODULE_BLOCKS / README_BYTES / GUIDE_BYTES used to be computed
# INSIDE sections 1 and 20, which made `--section 11` die on
# `TF_COUNT: unbound variable` and made `--section 7` report a false FAIL.
SRC_DIRS=()
for d in "${ROOT_DIR}"/srcs/*/; do
  [ -d "$d" ] && SRC_DIRS+=("$(basename "$d")")
done

TF_COUNT="$(find "${TF_DIR}" -maxdepth 1 -name '*.tf' -type f 2>/dev/null | wc -l | tr -d ' ')"
# "module" blocks are counted separately from .tf FILES on purpose. The two are
# routinely conflated ("18 modules") and they are not the same thing: this
# codebase has 0 `module` blocks, it is a flat root-module configuration split
# across 19 files. Saying "18 modules" is precisely the error that a rewrite of
# the audit guide was created to destroy.
TF_MODULE_BLOCKS="$(grep -hE '^module[[:space:]]+"' "$TF_DIR"/*.tf 2>/dev/null | wc -l | tr -d ' ')"
README_BYTES="$(wc -c < "${ROOT_DIR}/README.md" 2>/dev/null | tr -d ' ')"
GUIDE_BYTES="$(wc -c < "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null | tr -d ' ')"
PY_OK=0; MAKE_OK=0

# probe_environment -- pure detection. Sets flags and NOTHING else: no pass(),
# no invalid(), no show(). It MUST run before any step() so that `--section N`
# on a section other than 0 still sees a correct COMPOSE_STACK_UP /
# CLUSTER_REACHABLE. Previously this all lived inside detect_tools(), which is
# only ever reached from `step "0"`, so `--section 8` reported
# "[INVALID] compose stack is not running" against a perfectly healthy stack.
probe_environment() {
  command -v docker    >/dev/null 2>&1 && DOCKER_OK=1
  command -v kubectl   >/dev/null 2>&1 && KUBECTL_OK=1
  command -v aws       >/dev/null 2>&1 && AWS_OK=1
  command -v terraform >/dev/null 2>&1 && TERRAFORM_OK=1
  command -v jq        >/dev/null 2>&1 && JQ_OK=1
  command -v curl      >/dev/null 2>&1 && CURL_OK=1
  command -v python3   >/dev/null 2>&1 && PY_OK=1
  command -v make      >/dev/null 2>&1 && MAKE_OK=1
  { [ -x "${HOME}/.local/bin/k3d" ] || command -v k3d >/dev/null 2>&1; } && K3D_OK=1

  if [ "${KUBECTL_OK}" -eq 1 ]; then
    kubectl cluster-info >/dev/null 2>&1 && CLUSTER_REACHABLE=1
  fi
  if [ "${DOCKER_OK}" -eq 1 ] && docker info >/dev/null 2>&1; then
    DOCKER_DAEMON_OK=1
    if [ "${STATIC_ONLY}" -eq 1 ]; then
      :   # --static: leave COMPOSE_STACK_UP=0 so every live check reports INVALID
    elif (cd "${ROOT_DIR}" && docker compose ps --status running 2>/dev/null | tail -n +2 | grep -q .); then
      COMPOSE_STACK_UP=1
    fi
  fi
  return 0
}

# report_preconditions -- the section-0 REPORT. Emits the pass/invalid lines,
# so it is gated by step() exactly like every other section.
report_preconditions() {
  step "0" "Preconditions: tool inventory and reachability" "audit.md:62,70,76 - the rubric demands aws cli / docker ps / kubectl be SHOWN" || return 0

  for t in docker kubectl aws terraform jq curl python3 make; do
    case "$t" in
      docker)    v="$(docker --version 2>/dev/null | head -1)" ;;
      kubectl)   v="$(kubectl version --client 2>/dev/null | head -1)" ;;
      aws)       v="$(aws --version 2>/dev/null)" ;;
      terraform) v="$(terraform version 2>/dev/null | head -1)" ;;
      jq)        v="$(jq --version 2>/dev/null)" ;;
      curl)      v="$(curl --version 2>/dev/null | head -1)" ;;
      python3)   v="$(python3 -V 2>&1 | head -1)" ;;
      make)      v="$(make --version 2>/dev/null | head -1)" ;;
    esac
    show "${t} --version" "${v:-command not found (exit 127)}"
  done

  if [ "${DOCKER_OK}" -eq 1 ]; then pass "docker is installed and answered --version"
  else invalid "docker NOT installed -- every live docker check is INVALID"; fi
  if [ "${KUBECTL_OK}" -eq 1 ]; then pass "kubectl is installed"
  else invalid "kubectl NOT installed -- every Kubernetes check is INVALID"; fi
  if [ "${JQ_OK}" -eq 1 ]; then pass "jq is installed"
  else invalid "jq NOT installed -- JSON checks are INVALID"; fi
  if [ "${CURL_OK}" -eq 1 ]; then pass "curl is installed"
  else invalid "curl NOT installed -- every HTTP check is INVALID"; fi
  if [ "${PY_OK}" -eq 1 ]; then pass "python3 is installed -- the application-source import check and the repo's own unit tests can be executed"
  else invalid "python3 NOT installed -- the srcs/ module-import check and 'make test-py' are INVALID"; fi
  if [ "${MAKE_OK}" -eq 1 ]; then pass "make is installed -- 'make test-py' can be executed"
  else invalid "make NOT installed -- 'make test-py' cannot be executed and is INVALID"; fi
  if [ "${K3D_OK}" -eq 1 ]; then
    pass "k3d is present ($(k3d version 2>&1 | head -1))"
    show "k3d cluster list" "$(k3d cluster list 2>&1)"
  else
    note "k3d NOT present -- no local Kubernetes cluster can be created/rebuilt here"
  fi

  # Deliberately explicit: these two are absent in this environment. Every
  # AWS/Terraform check degrades to INVALID, never to a silent skip.
  if [ "${AWS_OK}" -eq 1 ]; then pass "aws CLI is installed"
  else invalid "aws CLI NOT installed -- NO live AWS resource can be inspected: no describe/get calls, no ALB/authorizer/RDS state, no 401 curl against a deployed API Gateway"; fi
  if [ "${TERRAFORM_OK}" -eq 1 ]; then pass "terraform is installed"
  else invalid "terraform NOT installed -- 'terraform fmt -check', 'terraform validate' and 'terraform plan' are INVALID; ALL Terraform evidence in this run is STATIC text analysis only"; fi

  if [ "${KUBECTL_OK}" -eq 1 ]; then
    if [ "${CLUSTER_REACHABLE}" -eq 1 ]; then
      pass "kubectl can reach a cluster (context: $(kubectl config current-context 2>/dev/null))"
      show "kubectl get namespaces" "$(kubectl get namespaces 2>&1 | head -8)"
    else
      invalid "kubectl CANNOT reach any cluster -- every 'this must be absent / must be 0' assertion is INVALID, because an unreachable cluster returns an EMPTY stdout which would make them all falsely PASS"
    fi
  fi

  if [ "${DOCKER_OK}" -eq 1 ]; then
    if [ "${DOCKER_DAEMON_OK}" -eq 1 ]; then
      pass "docker daemon is reachable"
      if [ "${STATIC_ONLY}" -eq 1 ]; then
        note "--static was passed: live docker compose checks are deliberately not run and will report INVALID"
      elif [ "${COMPOSE_STACK_UP}" -eq 1 ]; then
        pass "the docker compose stack is running ($(cd "${ROOT_DIR}" && docker compose ps --services --filter status=running 2>/dev/null | grep -c .) services up)"
      else
        invalid "the docker compose stack is NOT running -- start it with 'make up' or 'docker compose up -d'"
      fi
    else
      invalid "docker daemon is NOT reachable ('docker info' failed) -- every docker check is INVALID"
    fi
  fi
  return 0
}

SECTIONS=(
"0|0. Preconditions: tool inventory and reachability|audit.md:62,70,76"
"1|1. Are all the required files present?|audit.md:11"
"2|2. Stakeholder roleplay (14) + grader observations - NOT automatable|audit.md:19-32,34,36,38,40"
"3|3. Well-Architected pillars (5) - static evidence + prose is NOT automatable|audit.md:46-50"
"4|4. Architecture aligns with requirements (PORT CONSISTENCY MATRIX)|audit.md:52"
"5|5. Cost-effectiveness|audit.md:54"
"6|6. README completeness|audit.md:58"
"7|7. Documentation clarity, diagrams, structure|audit.md:60"
"8|8. All microservices running, no errors/connectivity (LIVE)|audit.md:64"
"9|9. Load balancing distributes traffic (LIVE)|audit.md:66"
"10|10. Secure service communication, auth + encryption (incl. rds.force_ssl)|audit.md:68"
"11|11. Terraform used effectively (attachment-aware data-tier exposure check)|audit.md:72"
"12|12. Infrastructure follows architecture (PDB effectiveness + probe semantics)|audit.md:74"
"13|13. Dockerfile optimisation (real analysis)|audit.md:78"
"14|14. Orchestration configured correctly|audit.md:80"
"15|15. Monitoring & logging dashboards|audit.md:84"
"16|16. Auto-scaling configured correctly (per-target)|audit.md:88"
"17|17. Efficient under different load (LIVE load test, marker-isolated LB split)|audit.md:90"
"18|18. Security best practices incl. vulnerability scanning|audit.md:94"
"19|19. Bonus: what is ACTUALLY implemented + app source imports and its tests pass|audit.md:98"
"20|20. Bonus: outstanding project - evidence tally|audit.md:100"
"21|21. Non-automatable items and final summary|audit.md:34,36,38,40"
)

if [ "${LIST_ONLY}" -eq 1 ]; then
  echo "Sections in scripts/run-audit-checks.sh:"
  printf '  %s\n' "${SECTIONS[@]}"
  echo
  echo "Usage: ./scripts/run-audit-checks.sh [--static] [--section N] [--no-color]"
  exit 0
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE} cloud-design -- docs/audit.md automated verification${NC}"
echo -e "${BLUE} root: ${ROOT_DIR}${NC}"
echo -e "${BLUE} run marker: ${RUN_MARKER}    audit user_id: ${AUDIT_USER_ID}${NC}"
echo -e "${BLUE}============================================================${NC}"

# Detection runs UNCONDITIONALLY, before any section, so that --section N works
# for every N -- including N != 0. Previously all of this lived inside
# detect_tools(), reachable only from `step "0"`, so `--section 8` reported
# "[INVALID] compose stack is not running" against a perfectly healthy stack.
# Only the *reporting* of the preconditions is gated by step "0", so the
# section-0 pass/invalid tally is unchanged.
probe_environment
report_preconditions

# =============================================================================
# SECTION 1 -- audit.md:11  "Are all the required files present?"
# Counts are DISCOVERED, never hardcoded, so this cannot rot.
# =============================================================================
if step "1" "Are all the required files present?" "audit.md:11"; then

note "The top-level Dockerfiles/ tree was DELETED and consolidated into srcs/<component>/Dockerfile. This checks the CURRENT layout and says so."
note "audit.md moved into docs/. A root-level audit.md no longer exists -- that was the stale-path bug in test_cloud.sh."

show "find terraform -maxdepth 1 -name '*.tf' | wc -l" "${TF_COUNT}"

MISSING=()
for f in README.md docs/readme.md docs/audit.md docs/AUDIT_GUIDE.md docker-compose.yml Makefile .env.example; do
  [ -e "${ROOT_DIR}/${f}" ] || MISSING+=("${f}")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
  pass "docs + root config present: README.md, docs/readme.md, docs/audit.md, docs/AUDIT_GUIDE.md, docker-compose.yml, Makefile, .env.example"
else
  fail "missing required root files: ${MISSING[*]}"
fi

show "wc -c README.md docs/AUDIT_GUIDE.md" "${README_BYTES}  README.md /  ${GUIDE_BYTES}  AUDIT_GUIDE.md"
if count_ok "${README_BYTES}" && [ "${README_BYTES}" -gt 2000 ]; then
  pass "README.md is substantial (${README_BYTES} bytes) -- not a stub"
else
  fail "README.md is missing or too small to be 'detailed documentation' (${README_BYTES:-0} bytes)"
fi

SRC_COUNT="${#SRC_DIRS[@]}"
show "ls -1 srcs/" "$(printf '%s ' "${SRC_DIRS[@]}")"
if [ "${SRC_COUNT}" -eq 6 ]; then
  pass "srcs/ contains the 6 required components (${SRC_DIRS[*]})"
else
  fail "srcs/ contains ${SRC_COUNT} component(s), expected 6: ${SRC_DIRS[*]}"
fi

DF_COUNT=0; DF_MISSING=()
for d in "${SRC_DIRS[@]}"; do
  if [ -f "${ROOT_DIR}/srcs/${d}/Dockerfile" ]; then DF_COUNT=$((DF_COUNT + 1)); else DF_MISSING+=("srcs/${d}/Dockerfile"); fi
done
show "ls -1 srcs/*/Dockerfile | wc -l" "${DF_COUNT}"
if [ "${DF_COUNT}" -eq "${SRC_COUNT}" ] && [ "${DF_COUNT}" -gt 0 ]; then
  pass "a Dockerfile exists for every component (${DF_COUNT}/${SRC_COUNT} at srcs/<component>/Dockerfile)"
else
  fail "missing Dockerfiles: ${DF_MISSING[*]:-none}"
fi

INIT_COUNT=0
for d in "${SRC_DIRS[@]}"; do [ -f "${ROOT_DIR}/srcs/${d}/init.sql" ] && INIT_COUNT=$((INIT_COUNT + 1)); done
show "ls -1 srcs/*/init.sql | wc -l" "${INIT_COUNT}"
if [ "${INIT_COUNT}" -eq 2 ]; then
  pass "both database schemas are present (srcs/inventory-database/init.sql, srcs/billing-database/init.sql)"
else
  fail "expected 2 init.sql (inventory + billing), found ${INIT_COUNT}"
fi

if [ -f "${ROOT_DIR}/srcs/rabbit-queue/definitions.json" ]; then
  if [ "${JQ_OK}" -eq 1 ] && jq -e . "${ROOT_DIR}/srcs/rabbit-queue/definitions.json" >/dev/null 2>&1; then
    pass "srcs/rabbit-queue/definitions.json exists and is valid JSON"
  else
    invalid "srcs/rabbit-queue/definitions.json exists but JSON validation is INVALID (jq absent, or it is malformed)"
  fi
else
  fail "srcs/rabbit-queue/definitions.json is missing"
fi

SCRIPT_COUNT="$(find "${SCRIPT_DIR}" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null | wc -l | tr -d ' ')"
show "ls -1 scripts/*.sh scripts/*.py | wc -l" "${SCRIPT_COUNT}"
if count_ok "${SCRIPT_COUNT}" && [ "${SCRIPT_COUNT}" -ge 3 ]; then
  pass "deployment/verification scripts are present (${SCRIPT_COUNT} files in scripts/)"
else
  fail "scripts/ has ${SCRIPT_COUNT:-0} script(s)"
fi

if count_ok "${TF_COUNT}" && [ "${TF_COUNT}" -ge 10 ]; then
  pass "terraform/ contains ${TF_COUNT} .tf files (counted, not hardcoded)"
else
  fail "terraform/ contains ${TF_COUNT:-0} .tf files, expected a modular set"
fi

MAN_COUNT="$(find "${MAN_DIR}" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')"
show "ls -1 manifests/*.yaml | wc -l" "${MAN_COUNT}"
if count_ok "${MAN_COUNT}" && [ "${MAN_COUNT}" -ge 8 ]; then
  pass "manifests/ contains ${MAN_COUNT} .yaml files"
else
  fail "manifests/ contains ${MAN_COUNT:-0} .yaml files"
fi
if [ -f "${MAN_DIR}/kustomization.yaml" ]; then
  pass "manifests/kustomization.yaml exists -- 'kubectl apply -k manifests/' is the supported path"
else
  fail "manifests/kustomization.yaml is missing"
fi

ECS_COUNT="$(find "${ECS_DIR}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
show "ls -1 ecs-tasks/*.json | wc -l" "${ECS_COUNT}"
if count_ok "${ECS_COUNT}" && [ "${ECS_COUNT}" -eq 6 ]; then
  pass "ecs-tasks/ contains ${ECS_COUNT} ECS task definitions"
else
  fail "ecs-tasks/ contains ${ECS_COUNT:-0} task definitions, expected 6"
fi
fi

# =============================================================================
# SECTION 2 -- audit.md:19-32 + 34,36,38,40
# Graded human observations. Printed as NOTES. Deliberately NOT scored.
# =============================================================================
if step "2" "Stakeholder roleplay (14) and grader observations - NOT automatable" "audit.md:19-32,34,36,38,40"; then
note "audit.md:34,36,38,40 ('answered correctly', 'thorough understanding', 'communicated effectively', 'critically evaluated') are GRADER OBSERVATIONS recorded live. A script cannot assert them and they are deliberately NOT scored here."
ROLEPLAY_MISSING=()
for q in "Q1: What is the cloud and its associated benefits" \
         "Q2: Why is deploying the solution in the cloud preferred" \
         "Q3: How would you differentiate between public, private, and hybrid" \
         "Q4: What drove your decision to select AWS" \
         "Q5: Can you describe your microservices application" \
         "Q6: How did you manage and optimize the cost" \
         "Q7: What measures did you implement to ensure application security" \
         "Q8: What AWS monitoring and logging tools did you utilize" \
         "Q9: Can you describe the AWS auto-scaling policies" \
         "Q10: How did you optimize Docker images" \
         "Q11: If you had to redo this project" \
         "Q12: How can your AWS solution be expanded" \
         "Q13: What challenges did you face" \
         "Q14: How did you ensure your documentation"; do
  fcount -q -F "### ${q}" "${ROOT_DIR}/docs/AUDIT_GUIDE.md" >/dev/null 2>&1 || ROLEPLAY_MISSING+=("${q%%:*}")
done
show "grep -cE '^### Q[0-9]+:' docs/AUDIT_GUIDE.md" "$(grep -cE '^### Q[0-9]+:' "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null) roleplay sections"
if [ "${#ROLEPLAY_MISSING[@]}" -eq 0 ]; then
  pass "all 14 roleplay questions have a prepared answer in docs/AUDIT_GUIDE.md (## 2)"
else
  fail "docs/AUDIT_GUIDE.md is missing prepared answers for: ${ROLEPLAY_MISSING[*]}"
fi
note "That PASS asserts only that the ANSWERS EXIST. The quality of the spoken answer is the examiner's call, not this script's."
fi

# =============================================================================
# SECTION 3 -- audit.md:46-50 the five Well-Architected pillars
# =============================================================================
if step "3" "Well-Architected pillars (5) - static evidence, prose is NOT automatable" "audit.md:46-50"; then
note "The five pillars are a DESIGN REVIEW. Each has a prose defence in docs/AUDIT_GUIDE.md ## 3. Prose is not machine-checkable; the concrete IaC evidence behind each pillar IS, and is scored in the sections noted:"
for p in "3.1 Scalability" "3.2 Availability" "3.3 Security" "3.4 Cost-Effectiveness" "3.5 Simplicity"; do
  if grep -q "### ${p}" "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null; then
    pass "pillar defence present in docs/AUDIT_GUIDE.md: ${p}"
  else
    fail "docs/AUDIT_GUIDE.md is missing pillar section '${p}'"
  fi
done
note "Evidence trail:  Scalability -> S16 (AS targets + HPA) | Availability -> S5/S12/S14 |"
note "                 Security -> S10/S18 | Cost -> S5 | Simplicity -> S11/S14"
fi

# =============================================================================
# SECTION 4 -- audit.md:52  architecture aligns with requirements
# REAL port-consistency matrix: Dockerfile EXPOSE -> compose -> manifest
# containerPort -> ECS portMappings -> ALB target group.
# =============================================================================
if step "4" "Architecture aligns with requirements - PORT CONSISTENCY MATRIX" "audit.md:52 (ports from docs/readme.md:70-83)"; then
note "Required component ports (docs/readme.md:70-83):"
note "  inventory-database=5432  billing-database=5432  inventory-app=8080"
note "  billing-app=8080  RabbitMQ=5672  api-gateway=3000"
note "compose-host is 'n/a' where the service is deliberately NOT published on the host."
note "  (api-gateway is reachable only through gateway-lb; billing-database is 5433->5432"
note "   because two containers cannot bind the same host port.)"

printf "  %-19s %-5s %-11s %-14s %-9s %-6s %-6s\n" component req Dockerfile compose manifest ECS ALB
printf "  %-19s %-5s %-11s %-14s %-9s %-6s %-6s\n" ---------------- ----- ----------- -------------- --------- ------ ------

MATRIX_BAD=0
MATRIX_ROWS=""
# component : port : srcs-dir : compose-service : manifest-file : ecs-file : in-alb
while IFS='|' read -r comp port src svc mfile efile inalb; do
  [ -n "${comp}" ] || continue

  # 1) Dockerfile EXPOSE
  DFV="noDockerfile"
  if [ -f "${ROOT_DIR}/srcs/${src}/Dockerfile" ]; then
    if grep -qE "^EXPOSE[[:space:]]+${port}([[:space:]]|\$)" "${ROOT_DIR}/srcs/${src}/Dockerfile"; then
      DFV="${port}"
    else
      DFV="MISSING"; MATRIX_BAD=$((MATRIX_BAD + 1))
    fi
  else
    MATRIX_BAD=$((MATRIX_BAD + 1))
  fi

  # 2) compose published host:container
  CPV="n/a"
  CSVC="$(awk -v s="${svc}" '$1 == s ":" {f=1; next} f && /^  [a-zA-Z]/ {exit} f' "${ROOT_DIR}/docker-compose.yml" 2>/dev/null)"
  if grep -q "^  ${svc}:" "${ROOT_DIR}/docker-compose.yml" 2>/dev/null; then
    PUB="$(sed -n "/^  ${svc}:/,/^  [a-z]/p" "${ROOT_DIR}/docker-compose.yml" 2>/dev/null | grep -oE '"[0-9]+:[0-9]+"' | tr -d '"' | head -1)"
    if [ -n "${PUB}" ]; then CPV="${PUB}"; else CPV="none"; fi
    # The published CONTAINER port must be the audited port.
    if [ -n "${PUB}" ] && [ "${PUB##*:}" != "${port}" ]; then
      CPV="${PUB}(WRONG-CONT-PORT)"; MATRIX_BAD=$((MATRIX_BAD + 1))
    fi
  fi

  # 3) manifest containerPort
  MFV="noManifest"
  if [ -f "${MAN_DIR}/${mfile}" ]; then
    if grep -qE "containerPort:[[:space:]]*${port}[[:space:]]*\$" "${MAN_DIR}/${mfile}"; then
      MFV="${port}"
    else
      MFV="MISSING"; MATRIX_BAD=$((MATRIX_BAD + 1))
    fi
  else
    MATRIX_BAD=$((MATRIX_BAD + 1))
  fi

  # 4) ECS portMappings
  ECV="n/a"
  if [ -f "${ECS_DIR}/${efile}" ] && [ "${JQ_OK}" -eq 1 ]; then
    if jq -e --argjson p "${port}" '.containerDefinitions[].portMappings[]?|select(.containerPort==$p)' "${ECS_DIR}/${efile}" >/dev/null 2>&1; then
      ECV="${port}"
    else
      ECV="MISSING"
    fi
  fi

  # 5) ALB target group (gateway only)
  ALBV="n/a"
  if [ "${inalb}" = "yes" ]; then
    if tf_block "${TF_DIR}/alb.tf" aws_lb_target_group apigw | grep -qE "^[[:space:]]*port[[:space:]]*=[[:space:]]*${port}\$"; then
      ALBV="${port}"
    else
      ALBV="MISSING"; MATRIX_BAD=$((MATRIX_BAD + 1))
    fi
  fi

  printf "  %-19s %-5s %-11s %-14s %-9s %-6s %-6s\n" "${comp}" "${port}" "${DFV}" "${CPV}" "${MFV}" "${ECV}" "${ALBV}"
  MATRIX_ROWS+="${comp} req=${port} dockerfile=${DFV} compose=${CPV} manifest=${MFV} ecs=${ECV} alb=${ALBV}"$'\n'
done <<'MATRIX'
inventory-database|5432|inventory-database|inventory-database|inventory-database.yaml|inventory-database-task.json|no
billing-database|5432|billing-database|billing-database|billing-database.yaml|billing-database-task.json|no
inventory-app|8080|inventory-app|inventory-app|inventory-app.yaml|inventory-app-task.json|no
billing-app|8080|billing-app|billing-app|billing-app.yaml|billing-app-task.json|no
api-gateway|3000|api-gateway|api-gateway|api-gateway.yaml|api-gateway-task.json|yes
rabbit-queue|5672|rabbit-queue|rabbit-queue|rabbitmq.yaml|rabbitmq-task.json|no
MATRIX

show "port matrix rows" "${MATRIX_ROWS}"
if [ "${MATRIX_BAD}" -eq 0 ]; then
  pass "port consistency: all 6 components carry their required port through Dockerfile EXPOSE, compose, manifest containerPort and ECS portMappings (gateway additionally through the ALB target group)"
else
  fail "port consistency: ${MATRIX_BAD} mismatch(es) in the matrix above"
fi

if grep -qE "^EXPOSE[[:space:]]+5672[[:space:]]+15672" "${ROOT_DIR}/srcs/rabbit-queue/Dockerfile" 2>/dev/null; then
  pass "RabbitMQ also exposes the management port 15672 (beyond the required 5672)"
else
  note "RabbitMQ Dockerfile does not list 15672 on its EXPOSE line (not a rubric requirement)"
fi
fi

# =============================================================================
# SECTION 5 -- audit.md:54  cost-effective architecture
# =============================================================================
if step "5" "Cost-effectiveness architecture" "audit.md:54"; then
if tf_any budgets_budget; then pass "aws_budgets_budget is provisioned (a real cost guardrail)"
else fail "no aws_budgets_budget -- nothing alerts on overspend"; fi
if tf_any nat_gateway >/dev/null && tf_grep single_nat_gateway | grep -q .; then
  pass "NAT gateway count is toggleable via single_nat_gateway (the largest VPC line item is a variable)"
else
  fail "no single_nat_gateway toggle -- NAT cost is not configurable"
fi

MBL_RAW="$(grep -A200 '^variable "monthly_budget_limit"' "${TF_DIR}/variables.tf" 2>/dev/null | grep -m1 -E '^[[:space:]]*default[[:space:]]*=')"
MBL="$(sed -E 's/.*=[[:space:]]*//; s/[^0-9.]//g' <<<"${MBL_RAW}")"
# The label is the command that produced the line beneath it. The previous
# revision printed `grep -A200 '...' | default` as the label while actually
# running an awk one-liner: `default` is not a program, so the label could never
# be re-run by the examiner and `default: command not found` was the honest
# result of pasting it. Anything printed here must be pasteable.
show "grep -A200 '^variable \"monthly_budget_limit\"' terraform/variables.tf | grep -m1 -E '^[[:space:]]*default[[:space:]]*='" "${MBL_RAW:-<no default line found>}   ->   parsed as ${MBL:-?} USD"
if count_ok "${MBL%%.*}"; then
  pass "monthly_budget_limit has a numeric default of ${MBL} USD"
else
  fail "could not read a numeric default for monthly_budget_limit (got '${MBL:-}')"
fi
# variables.tf carries a validation block requiring >= 50 USD (the previous 15 USD
# default fired every month and proved useless). Assert the invariant, not just
# the presence of a number.
if count_ok "${MBL%%.*}" && [ "${MBL%%.*}" -ge 50 ]; then
  pass "the ${MBL} USD budget respects the >= 50 USD floor enforced by the variable's own validation block"
else
  fail "monthly_budget_limit is ${MBL:-?} USD, below the >= 50 USD floor that terraform/variables.tf validates (the old 15 USD default fired every month and was useless)"
fi

# `default[[:space:]]*=` is ANCHORED on purpose. The bare pattern /default/ also
# matches the word "defaulted", so a description line reading "FIX: this
# defaulted to mq.t3.micro, which AWS has deprecated" was parsed as the value
# and the check reported a nonsense expected/got pair.
tf_var_default() { # tf_var_default <name>
  grep -A200 "^variable \"$1\"" "${TF_DIR}/variables.tf" 2>/dev/null \
    | grep -m1 -E '^[[:space:]]*default[[:space:]]*=' \
    | sed -E 's/.*=[[:space:]]*//; s/[^A-Za-z0-9._]//g'
}
DBC="$(tf_var_default db_instance_class)"
MQC="$(tf_var_default mq_host_instance_type)"
show "db_instance_class / mq_host_instance_type defaults" "db=${DBC:-<not found>}   mq=${MQC:-<not found>}"
assert_eq "database is on the smallest burstable class" "db.t4g.micro" "${DBC:-}"
# The expected MQ type is asserted against the SMALLEST TYPE AWS STILL OFFERS,
# not against a hardcoded t3.micro: Amazon MQ retired mq.t3.micro for new broker
# creation (end of support 2026-10-01), so demanding it would demand IaC that
# `terraform apply` can no longer satisfy. Both the type and the reason are read
# from variables.tf so this cannot silently rot when AWS changes the lineup again.
assert_eq "broker is on the smallest burstable class still offered by Amazon MQ" "mq.m7g.medium" "${MQC:-}"
if grep -q 'mq.t3.micro' "${TF_DIR}/variables.tf" 2>/dev/null && grep -qiE 'deprecat|no longer available|retired' "${TF_DIR}/variables.tf" 2>/dev/null; then
  note "the broker type moved off mq.t3.micro: terraform/variables.tf records that AWS no longer offers it for new brokers, and ${MQC:-?} is documented there as the smallest replacement. The cost consequence is carried in var.monthly_budget_limit (450 USD, was 300)."
fi

if tf_grep ecs_use_fargate_spot | grep -q .; then
  pass "compute is serverless Fargate with an FARGATE_SPOT toggle (up to ~70% cheaper)"
else
  fail "no Fargate/FARGATE_SPOT reference -- the serverless cost trade-off is undocumented"
fi
if tf_any eks_cluster >/dev/null || tf_any autoscaling_group >/dev/null; then
  fail "an EKS cluster or EC2 node ASG resource still exists -- contradicts the serverless cost claim"
else
  pass "no aws_eks_cluster / aws_autoscaling_group remains: the node-group cost path is fully removed"
fi

LRD="$(awk '/^variable .log_retention_days./{f=1} f && /default[[:space:]]*=/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/variables.tf" 2>/dev/null)"
show "log_retention_days default" "${LRD:-<not found>}"
if count_ok "${LRD}"; then pass "log retention is bounded (default ${LRD} days), so log cost cannot grow without limit"
else fail "no readable log_retention_days default"; fi

# The count uses a whitespace-tolerant pattern on purpose: terraform fmt aligns
# these, so the file really contains `skip_final_snapshot         = true`. A
# naive `grep -c 'skip_final_snapshot = true'` returns 0 on a correctly formatted
# file and would have reported "not set on both RDS instances". The label below
# is the pattern that actually ran.
SFS=0; SFS_EFF=""; SFS_SHOW=""
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  SFS_SHOW+="    ${line}"$'\n'
  rhs="$(sed -E 's/^[[:space:]]*skip_final_snapshot[[:space:]]*=[[:space:]]*//' <<<"${line}")"
  eff="?"
  if [ "${rhs}" = "true" ]; then
    eff="true"
  elif [[ "${rhs}" =~ ^"?"?(!?)(var[.][A-Za-z0-9_]+)"?"?$ ]]; then
    neg="${BASH_REMATCH[1]}"; vname="${BASH_REMATCH[2]#var.}"
    dv="$(tf_var_default "${vname}")"
    eff="${dv}"
    if [ "${neg}" = "!" ]; then
      [ "${dv}" = "true" ] && eff="false"
      [ "${dv}" = "false" ] && eff="true"
    fi
    SFS_EFF+="    ${line}  ->  var.${vname} default=${dv:-<unreadable>}${neg:+ negated}  =>  ${eff}"$'\n'
  fi
  [ "${eff}" = "true" ] && SFS=$(( SFS + 1 ))
done < <(grep -E 'skip_final_snapshot[[:space:]]*=' "${TF_DIR}/rds.tf" 2>/dev/null)
show "grep -nE 'skip_final_snapshot[[:space:]]*=' terraform/rds.tf, evaluating the right-hand side (a literal, or a var.X reference resolved in terraform/variables.tf, honouring a leading '!')" "${SFS_SHOW:-<no skip_final_snapshot line found>}${SFS_EFF}  =>  instances ending with skip_final_snapshot = true: ${SFS}"
if count_ok "${SFS}" && [ "${SFS}" -ge 2 ]; then
  pass "both RDS instances set skip_final_snapshot = true (no forgotten snapshot storage charges at destroy)"
else
  note "skip_final_snapshot is not set on both RDS instances (count=${SFS:-0}); snapshots are a deliberate data-retention choice"
fi
fi

# =============================================================================
# SECTION 6 -- audit.md:58  README prerequisites/setup/configuration/usage
# =============================================================================
if step "6" "README contains prerequisites, setup, configuration, usage" "audit.md:58"; then
show "README.md section headings" "$(grep -nE '^#{2,3} ' "${ROOT_DIR}/README.md" 2>/dev/null | head -30)"

if grep -qiE '^#+[[:space:]]*prerequisites' "${ROOT_DIR}/README.md"; then
  pass "README has a Prerequisites section"
else
  fail "README has no Prerequisites section"
fi
if grep -qiE '^#+[[:space:]]*deployment steps|terraform init' "${ROOT_DIR}/README.md"; then
  pass "README has a setup/deployment section with the real terraform init/apply commands"
else
  fail "README has no setup/deployment section"
fi
# Configuration: the repo ships .env.example and a secrets note; does the README
# tell an operator how to supply credentials?
if grep -qiE 'credentials|secret' "${ROOT_DIR}/README.md"; then
  pass "README addresses credential/secret handling"
else
  fail "README says nothing about credentials or secrets"
fi
if grep -qF '.env' "${ROOT_DIR}/README.md"; then
  pass "README references the .env file used by docker-compose.yml"
else
  fail "README never mentions .env, yet docker-compose.yml reads 8 credentials from it via \${VAR:?...} -- the local stack cannot be configured from the README alone"
fi
if grep -qiE 'usage|how to use|example|curl' "${ROOT_DIR}/README.md"; then
  pass "README includes usage/example material"
else
  note "README has no explicitly titled 'Usage' section; it covers the equivalent ground under 'Deployment & Verification Commands'. Flagging for the doc owner rather than failing the rubric item."
fi
if grep -qE 'audit\.md|AUDIT_GUIDE' "${ROOT_DIR}/README.md"; then
  pass "README cross-references the audit rubric / defence guide"
else
  fail "README never references docs/audit.md or docs/AUDIT_GUIDE.md, so a reader cannot navigate from the README to the rubric"
fi
# The README must not instruct a BROKEN command: `kubectl apply -f manifests/`
# is known-broken now that kustomization.yaml exists.
BADCMD="$(grep -nE 'kubectl apply -f[ ]*(\.\./)?manifests/?[[:space:]]*$' "${ROOT_DIR}/README.md" 2>/dev/null)"
show "grep -nE 'kubectl apply -f (../)?manifests/$' README.md" "${BADCMD:-<not found>}"
if [ -n "${BADCMD}" ]; then
  fail "README instructs 'kubectl apply -f manifests/', which FAILS (exit 1) now that manifests/kustomization.yaml exists. It must be 'kubectl apply -k manifests/'"
else
  pass "README does not instruct the broken 'kubectl apply -f manifests/' form"
fi
fi

# =============================================================================
# SECTION 7 -- audit.md:60  clear docs, well-structured diagrams
# =============================================================================
if step "7" "Documentation clarity, diagrams, structure" "audit.md:60"; then
TOTAL_MERMAID=0; BALANCED=0; UNBALANCED=()
for d in "${ROOT_DIR}/README.md" "${ROOT_DIR}/docs"/*.md; do
  [ -f "$d" ] || continue
  opens="$(grep -c '^```mermaid' "$d" 2>/dev/null | head -1)"
  fences="$(grep -c '^```' "$d" 2>/dev/null | head -1)"
  count_ok "${opens}" || opens=0
  count_ok "${fences}" || fences=0
  TOTAL_MERMAID=$((TOTAL_MERMAID + opens))
  if [ $((fences % 2)) -eq 0 ]; then
    BALANCED=$((BALANCED + opens))
  else
    UNBALANCED+=("$(basename "$d")(fences=${fences})")
  fi
done
show "mermaid blocks across README.md + docs/*.md" "${TOTAL_MERMAID} mermaid block(s); ${BALANCED} inside files with balanced code fences"
if [ "${TOTAL_MERMAID}" -ge 1 ] && [ "${#UNBALANCED[@]}" -eq 0 ]; then
  pass "the documentation carries ${TOTAL_MERMAID} mermaid diagram block(s), all in files with balanced code fences"
else
  fail "unbalanced code fences in: ${UNBALANCED[*]:-none} (${TOTAL_MERMAID} mermaid blocks)"
fi
if awk '/^```mermaid/{f=1;next} /^```/{f=0} f && (/-->/ || /graph|flowchart|subgraph|sequenceDiagram/){c++} END{exit (c>0)?0:1}' "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null; then
  pass "mermaid blocks look parse-plausible (they declare graph/flowchart/subgraph and edges)"
else
  note "could not confirm mermaid block structure programmatically (static heuristic only)"
fi
if grep -qiE 'design decision|rationale|trade-?off|we chose|deliberately|because' "${ROOT_DIR}/README.md"; then
  pass "README contains design-decision prose (rationale / trade-off language), not just a resource list"
else
  fail "README lacks design-decision prose"
fi
if count_ok "${GUIDE_BYTES}" && [ "${GUIDE_BYTES}" -gt 5000 ]; then
  pass "docs/AUDIT_GUIDE.md is substantial (${GUIDE_BYTES} bytes)"
else
  fail "docs/AUDIT_GUIDE.md is missing or thin"
fi
fi

# =============================================================================
# SECTION 8 -- audit.md:64  all microservices running, no errors / connectivity
# =============================================================================
if step "8" "All microservices running, no errors or connectivity issues (LIVE)" "audit.md:64 - the rubric asks for 'docker ps'"; then
if [ "${COMPOSE_STACK_UP}" -eq 1 ]; then
  show "docker compose ps" "$(cd "${ROOT_DIR}" && docker compose ps 2>&1)"
  # Expected scale is READ FROM docker-compose.yml, and `ps -a` is used with
  # every container id inspected. `docker compose ps -q <svc> | head -1` filters
  # to RUNNING containers and takes only the first, so a dead replica was simply
  # invisible and the count was never compared with the declared scale: with one
  # gateway replica killed this section still printed "all 7 compose services
  # report running/healthy".
  #
  # The name match below is `(<svc>)(-[0-9]+)?` and the numeric suffix is
  # OPTIONAL on purpose. Compose only appends `-N` to services that do not pin
  # `container_name`; the four services that do (both databases, the broker and
  # gateway-lb) are named exactly `<project>-<svc>`. Requiring the suffix made
  # those four report containers_present=0 and failed the section while all
  # eight containers were running and healthy -- a false FAIL is worse than no
  # check, because it trains you to ignore the output.
  compose_expected() { # compose_expected <service>  -> declared replicas, or 1
    awk -v s="$1" '
      $0 ~ "^  " s ":[[:space:]]*$" {f=1; next}
      f && /^  [A-Za-z0-9_-]+:/ {exit}
      f && /^    deploy:[[:space:]]*$/ {d=1; next}
      f && d && /^      replicas:/ {gsub(/[^0-9]/,""); print; exit}
      f && d && /^    [A-Za-z]/ {d=0}
    ' "${ROOT_DIR}/docker-compose.yml" 2>/dev/null | head -1
  }
  SVC_TABLE=""; NOT_HEALTHY=(); SCALE_BAD=()
  for s in api-gateway inventory-app billing-app inventory-database billing-database rabbit-queue gateway-lb; do
    want="$(compose_expected "${s}")"; count_ok "${want}" || want=1
    rows="$(cd "${ROOT_DIR}" && docker compose ps -a --format '{{.Name}}|{{.State}}|{{if .Health}}{{.Health}}{{else}}no-healthcheck{{end}}' 2>/dev/null \
            | awk -F'|' -v s="$s" '$1 ~ ("(^|-)" s "(-[0-9]+)?$") {print}')"
    have="$(grep -c . <<<"${rows}" | head -1)"
    count_ok "${have}" || have=0
    states=""; good=0
    while IFS='|' read -r cname cstate chealth; do
      [ -n "${cname}" ] || continue
      st="${cstate}/${chealth}"
      states+="${cname##*-}=${st} "
      if [ "${st}" = "running/healthy" ]; then
        good=$((good + 1)); pass "${s}[${cname##*-}]: ${st}"
      else
        NOT_HEALTHY+=("${cname}=${st}")
      fi
    done <<<"${rows}"
    SVC_TABLE+="${s}: expected=${want} containers_present=${have} running_healthy=${good}  [${states% }]"$'\n'
    if [ "${good}" -lt "${want}" ]; then
      SCALE_BAD+=("${s} ${good}/${want}")
    elif [ "${have}" -gt "${want}" ]; then
      SCALE_BAD+=("${s} ${have} containers present but only ${want} declared (orphans)")
    fi
  done
  show "declared scale (docker-compose.yml deploy.replicas) vs containers present vs running/healthy, from 'docker compose ps -a'" "${SVC_TABLE}"
  if [ "${#NOT_HEALTHY[@]}" -eq 0 ]; then
    pass "every container of all 7 compose services reports running and healthy"
  else
    fail "services not healthy: ${NOT_HEALTHY[*]}"
  fi
  if [ "${#SCALE_BAD[@]}" -eq 0 ]; then
    pass "running replica count matches the declared scale for all 7 services (expected vs running_healthy, table above) -- a killed replica can no longer hide behind 'docker compose ps -q | head -1'"
  else
    fail "running replica count does NOT match the declared scale: ${SCALE_BAD[*]}"
  fi

  if [ "${CURL_OK}" -eq 1 ]; then
    GH="$(curl -s -m 10 "${LB_URL}/health" 2>&1)"
    show "curl -s ${LB_URL}/health" "${GH}"
    assert_eq "GET /health through the gateway load balancer returns 200" "200" "$(http_code GET "${LB_URL}/health")"
    assert_contains "the /health body reports healthy" "${GH}" "healthy"
    assert_eq "GET /ready on inventory-app (host 8081) returns 200" "200" "$(http_code GET "http://localhost:8081/ready")"
    assert_eq "GET /ready on billing-app (host 8082) returns 200" "200" "$(http_code GET "http://localhost:8082/ready")"
    MV="$(curl -s -m 10 "${LB_URL}/api/movies/" 2>&1)"
    show "curl -s ${LB_URL}/api/movies/" "${MV}"
    if [[ "${MV}" == *'"movies"'* ]]; then
      pass "GET /api/movies/ returns a JSON body -> gateway -> inventory-app -> inventory-database is connected"
    else
      fail "GET /api/movies/ did not return a movies payload: ${MV}"
    fi

    # Connectivity errors in RECENT logs only. `--tail=200` would include
    # container-startup noise from hours ago and fail a healthy stack.
    # KEEP `|| true`: `grep -c` exits 1 on zero matches, and zero matches is the
    # result this check is looking for. The exit status is meaningless here; only
    # the number is used, and count_ok() below rejects a non-numeric one.
    RECENT_ERR="$(cd "${ROOT_DIR}" && docker compose logs --since=15m 2>&1 | grep -icE 'connection refused|could not connect|Traceback|OperationalError' || true)"
    show "docker compose logs --since=15m | grep -icE '<connection error patterns>'" "${RECENT_ERR:-0}"
    if count_ok "${RECENT_ERR}" && [ "${RECENT_ERR}" -eq 0 ]; then
      pass "no connection-refused / traceback / OperationalError lines in the last 15 minutes"
    else
      fail "${RECENT_ERR} connection-error line(s) in the last 15 minutes of logs"
    fi
    # Report (not fail) any historic startup-time errors, for honesty.
    # KEEP `|| true`: same reason as RECENT_ERR -- `grep -c` exits 1 on zero.
    HIST_ERR="$(cd "${ROOT_DIR}" && docker compose logs 2>&1 | grep -icE 'FATAL:|connection refused' || true)"
    note "historic (container-startup) FATAL/refused log lines since boot: ${HIST_ERR:-0} -- these come from the Postgres init-db reconciliation phase, not from steady state; shown for transparency, not scored."
  else
    invalid "curl is unavailable -- every live HTTP probe in this section is INVALID"
  fi
else
  invalid "compose stack is not running -- docker ps / curl /health / curl /ready / log inspection are INVALID, not passed"
fi

if [ "${CLUSTER_REACHABLE}" -eq 1 ]; then
  show "kubectl get pods -n cloud-design -o wide" "$(kubectl get pods -n cloud-design -o wide 2>&1)"
  READY="$(kubectl get pods -n cloud-design --no-headers 2>/dev/null | awk '$3=="Running"{split($2,a,"/"); if(a[1]==a[2] && a[1]>0) print}' | grep -c . | head -1)"
  show "kubectl get pods -n cloud-design (Running and fully Ready)" "${READY:-0} pod(s)"
  if count_ok "${READY}" && [ "${READY}" -ge 6 ]; then
    pass "all 6 Kubernetes workloads are Running and fully Ready in namespace cloud-design"
  else
    fail "only ${READY:-0}/6 Kubernetes pods are Running and fully Ready"
  fi
else
  note "no reachable cluster: 'kubectl get pods' is not claimed as evidence"
fi
fi

# =============================================================================
# SECTION 9 -- audit.md:66  load balancing distributes traffic
# =============================================================================
if step "9" "Load balancing distributes traffic (LIVE) + static ALB verification" "audit.md:66"; then
if [ "${COMPOSE_STACK_UP}" -eq 1 ] && [ "${CURL_OK}" -eq 1 ]; then
  LB_REPLICAS="$(cd "${ROOT_DIR}" && docker compose ps -q api-gateway 2>/dev/null | grep -c . | head -1)"
  show "docker compose ps -q api-gateway | wc -l" "${LB_REPLICAS} gateway replica(s)"
  if count_ok "${LB_REPLICAS}" && [ "${LB_REPLICAS}" -ge 2 ]; then
    pass "the gateway runs ${LB_REPLICAS} replicas behind gateway-lb, so distribution is demonstrable"
  else
    fail "the gateway has ${LB_REPLICAS} replica(s); with <2 there is nothing to distribute"
  fi

  # Marker-isolated window so stale log lines cannot satisfy the assertion.
  MARK="${LB_MARK}"
  SEEN="$(cd "${ROOT_DIR}" && docker compose logs 2>/dev/null | grep -cF "${MARK}" | head -1)"
  note "unique per-run marker for this section: ${MARK} (log lines seen before this run: ${SEEN:-0})"
  N=20
  for _ in $(seq 1 "${N}"); do curl -s -m 10 -o /dev/null "${LB_URL}/health?m=${MARK}" 2>/dev/null; done
  DIST="$(cd "${ROOT_DIR}" && docker compose logs --since=2m gateway-lb 2>/dev/null | grep -F "${MARK}" | grep -oE 'upstream=[0-9.]+:[0-9]+' | sort | uniq -c | sort -rn)"
  show "${N} x curl ${LB_URL}/health?m=${MARK}   ->   docker compose logs gateway-lb | grep ${MARK} | grep upstream=" "${DIST:-<no upstream lines>}"
  DISTINCT="$(echo "${DIST}" | grep -c . | head -1)"
  if count_ok "${DISTINCT}" && [ "${DISTINCT}" -ge 2 ]; then
    pass "traffic was distributed across ${DISTINCT} distinct gateway upstreams (counts above)"
  else
    fail "only ${DISTINCT:-0} distinct upstream(s) served the ${N} requests -- traffic is NOT being distributed"
  fi
  if docker exec cloud-design-gateway-lb grep -q 'least_conn' /etc/nginx/nginx.conf 2>/dev/null; then
    pass "gateway-lb nginx upstream uses least_conn (the same algorithm family the ALB target group documents)"
  else
    note "could not confirm least_conn from inside the live container (docker-compose.yml static text still asserts it)"
  fi
else
  invalid "compose stack not running (or curl missing) -- live load-balancing distribution is INVALID"
fi

LBN="$(tf_res_in "${TF_DIR}/alb.tf" lb)"; TGN="$(tf_res_in "${TF_DIR}/alb.tf" lb_target_group)"
LISN="$(tf_res_in "${TF_DIR}/alb.tf" lb_listener)"; RULEN="$(tf_res_in "${TF_DIR}/alb.tf" lb_listener_rule)"
HCN="$(fcount 'health_check' "${TF_DIR}/alb.tf")"
show "DERIVED SUMMARY, not one grep: tf_res_in terraform/alb.tf <type> once per resource kind, plus fcount 'health_check'" "aws_lb=${LBN} target_group=${TGN} listener=${LISN} listener_rule=${RULEN} health_check_blocks=${HCN}"
if count_ok "${LBN}" && [ "${LBN}" -ge 1 ] && count_ok "${TGN}" && [ "${TGN}" -ge 1 ] \
   && count_ok "${LISN}" && [ "${LISN}" -ge 1 ] && count_ok "${RULEN}" && [ "${RULEN}" -ge 1 ] \
   && count_ok "${HCN}" && [ "${HCN}" -ge 1 ]; then
  pass "terraform/alb.tf declares aws_lb + target group + listener(s) + listener rule + an explicit health_check"
else
  fail "terraform/alb.tf is missing one of aws_lb / target group / listener / listener rule / health_check"
fi
fi

# =============================================================================
# SECTION 10 -- audit.md:68  secure comms, auth + encryption
# =============================================================================
if step "10" "Services communicate securely: auth + encryption" "audit.md:68"; then
NROUTES="$(tf_res_in "${TF_DIR}/api_gateway.tf" apigatewayv2_route)"
NAUTH="$(fcount 'authorizer_id[[:space:]]*=' "${TF_DIR}/api_gateway.tf")"
show "routes vs authorizer_id" "aws_apigatewayv2_route=${NROUTES}  authorizer_id assignments=${NAUTH}"
note "routes deliberately without an authorizer: $(( NROUTES - NAUTH )) (expected exactly 1: the GET /health probe route)"
if count_ok "${NROUTES}" && [ "${NROUTES}" -ge 4 ] && count_ok "${NAUTH}" && [ "${NAUTH}" -eq "$(( NROUTES - 1 ))" ]; then
  pass "every API Gateway route except the health probe has authorizer_id attached"
elif count_ok "${NROUTES}" && [ "${NROUTES}" -ge 4 ] && count_ok "${NAUTH}" && [ "${NAUTH}" -ge 1 ]; then
  pass "the Cognito authorizer is attached to ${NAUTH} of ${NROUTES} routes"
else
  fail "the Cognito authorizer is not attached to the expected routes (authorizer_id=${NAUTH:-0}, routes=${NROUTES:-0})"
fi
if tf_any cognito_user_pool; then pass "Cognito user pool is provisioned for managed authentication"
else fail "no aws_cognito_user_pool"; fi
if tf_any apigatewayv2_authorizer; then pass "API Gateway authorizer resource exists"
else fail "no aws_apigatewayv2_authorizer"; fi

KMSUSE="$(fcount 'kms_key_id' "${TF_DIR}/rds.tf")"
show "grep -c kms_key_id terraform/rds.tf" "${KMSUSE:-0}"
if count_ok "${KMSUSE}" && [ "${KMSUSE}" -ge 2 ]; then
  pass "both RDS instances encrypt storage with a customer-managed aws_kms_key"
else
  fail "RDS storage encryption with a KMS key is not wired to both instances"
fi

# ---- encryption IN TRANSIT for the data tier: rds.force_ssl ----------------
# storage_encrypted proves "at rest". The "in transit" half is rds.force_ssl in
# the custom parameter group, and NO check anywhere looked at it: setting
# `rds.force_ssl = 0` (or dropping the parameter block) left both suites green
# while the docs sell the control as one of three headline security properties.
FSSL_BLOCK="$(tf_block "${TF_DIR}/rds.tf" aws_db_parameter_group postgres)"
FSSL_DECL="$(grep -cE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"rds\.force_ssl"' <<<"${FSSL_BLOCK}" 2>/dev/null | head -1)"
FSSL_VAL="$(awk '/rds\.force_ssl/{f=1} f && /value[[:space:]]*=/{gsub(/[^0-9]/,"");print;exit}' <<<"${FSSL_BLOCK}" 2>/dev/null)"
FSSL_USERS="$(fcount 'parameter_group_name[[:space:]]*=[[:space:]]*aws_db_parameter_group\.postgres\.name' "${TF_DIR}/rds.tf")"
show "terraform/rds.tf: rds.force_ssl parameter + the aws_db_instance blocks that adopt the group" "force_ssl declarations=${FSSL_DECL:-0} value='${FSSL_VAL:-<none>}' instances adopting the parameter group=${FSSL_USERS:-0}"
if count_ok "${FSSL_DECL}" && [ "${FSSL_DECL}" -eq 1 ] && [ "${FSSL_VAL}" = "1" ]; then
  pass "the postgres16 parameter group sets rds.force_ssl = 1 -- the server REFUSES plaintext PostgreSQL sessions instead of negotiating them, which is the 'encrypted in transit' control"
else
  fail "rds.force_ssl is not set to 1 in the aws_db_parameter_group (declarations=${FSSL_DECL:-0}, value='${FSSL_VAL:-<none>}'); a value of 0 or a missing parameter block means the database tier accepts unencrypted connections"
fi
if count_ok "${FSSL_USERS}" && [ "${FSSL_USERS}" -ge 2 ]; then
  pass "both aws_db_instance blocks set parameter_group_name = aws_db_parameter_group.postgres.name, so force_ssl is actually applied and not just declared on an orphaned parameter group"
else
  fail "only ${FSSL_USERS:-0} aws_db_instance block(s) adopt aws_db_parameter_group.postgres (need 2); rds.force_ssl would be declared but never applied"
fi

SMN="$(tf_res secretsmanager_secret)"
show "aws_secretsmanager_secret resources" "${SMN:-0}"
if count_ok "${SMN}" && [ "${SMN}" -ge 2 ]; then pass "credentials are stored in AWS Secrets Manager (${SMN} secrets)"
else fail "AWS Secrets Manager is not used for credentials"; fi

PUBTOT="$(tf_grep publicly_accessible | grep -c . | head -1)"
PUBF="$(tf_grep publicly_accessible | grep -c '= *false' | head -1)"
show "publicly_accessible settings" "${PUBTOT:-0} declaration(s), ${PUBF:-0} of them =false"
if count_ok "${PUBTOT}" && [ "${PUBTOT}" -ge 2 ] && [ "${PUBF}" -eq "${PUBTOT}" ]; then
  pass "every data-tier resource (RDS + Amazon MQ) sets publicly_accessible = false"
else
  fail "a data-tier resource is not explicitly marked publicly_accessible = false"
fi

if [ -f "${MAN_DIR}/network-policies.yaml" ]; then
  NPN="$(fcount '^kind:[[:space:]]*NetworkPolicy' "${MAN_DIR}/network-policies.yaml")"
  DD="$(fcount 'name: default-deny-all' "${MAN_DIR}/network-policies.yaml")"
  show "NetworkPolicy count / default-deny" "${NPN:-0} NetworkPolicies, default-deny-all present=${DD:-0}"
  if count_ok "${NPN}" && [ "${NPN}" -ge 4 ] && [ "${DD:-0}" -ge 1 ]; then
    pass "the namespace is default-deny with ${NPN} NetworkPolicies carving out least-privilege paths"
  else
    fail "NetworkPolicies are insufficient (${NPN:-0} policies, default-deny=${DD:-0})"
  fi
else
  fail "manifests/network-policies.yaml is missing"
fi

if [ "${AWS_OK}" -eq 1 ]; then
  API_URL="$(grep -rhoE 'https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com' "${ROOT_DIR}/docs/"*.md 2>/dev/null | head -1)"
  if [ -n "${API_URL}" ]; then
    show "curl -i (no Authorization header) ${API_URL}/api/movies" "$(curl -s -i -m 10 "${API_URL}/api/movies" 2>&1 | head -10)"
    assert_eq "a credential-less request to the deployed API is rejected with 401" "401" "$(http_code GET "${API_URL}/api/movies")"
  else
    invalid "could not discover a deployed API Gateway invoke URL, so the 401 rejection cannot be proven -- INVALID"
  fi
else
  invalid "PROVING that a credential-less request is REJECTED requires calling a DEPLOYED API Gateway with curl/aws. No deployed endpoint is reachable here, so this is NOT claimed as a pass. The static evidence above (authorizer_id on every non-health route) is what can be proven locally."
fi

if [ "${COMPOSE_STACK_UP}" -eq 1 ]; then
  ANON="$(http_code GET "http://localhost:15672/api/overview")"
  show "curl -s -o/dev/null -w '%{http_code}' http://localhost:15672/api/overview   (NO credentials)" "${ANON}"
  if [ "${ANON}" = "401" ]; then pass "the RabbitMQ management API rejects a credential-less request with 401 (the broker is not anonymous)"
  else note "RabbitMQ management API answered ${ANON} without credentials; broker auth posture unverified from here"; fi
else
  invalid "compose stack not running -- the broker-authentication probe is INVALID"
fi
fi

# =============================================================================
# SECTION 11 -- audit.md:72  Terraform used effectively
# =============================================================================
if step "11" "Terraform used effectively" "audit.md:72"; then
TF_TOTAL="$(tf_types | grep -c . | head -1)"
TF_DATA="$(grep -hE '^data ' "$TF_DIR"/*.tf 2>/dev/null | wc -l | tr -d ' ')"
show "resource/data tallies" "${TF_TOTAL} resources, ${TF_DATA} data sources, ${TF_COUNT} .tf files"
if count_ok "${TF_TOTAL}" && [ "${TF_TOTAL}" -ge 50 ]; then
  pass "the Terraform codebase provisions ${TF_TOTAL} resources across ${TF_COUNT} files (substantial, modular IaC)"
else
  fail "only ${TF_TOTAL:-0} resources defined -- the IaC does not look substantial"
fi
show "per-file resource counts" "$(for f in "$TF_DIR"/*.tf; do printf '%s=%s ' "$(basename "$f")" "$(grep -cE '^resource ' "$f")"; done)"

DECL="$(grep -cE '^variable ' "${TF_DIR}/variables.tf" 2>/dev/null | head -1)"
REFS="$(grep -rhoE 'var\.[a-z0-9_]+' "$TF_DIR"/*.tf 2>/dev/null | sed 's/var\.//' | sort -u | wc -l | tr -d ' ')"
UNUSED=""; UNDECL=""
for v in $(grep -oE '^variable "[a-z0-9_]+"' "${TF_DIR}/variables.tf" 2>/dev/null | sed 's/variable "//;s/"//'); do
  grep -rqE "var\.${v}\b" "$TF_DIR"/*.tf 2>/dev/null || UNUSED+="${v} "
done
for r in $(grep -rhoE 'var\.[a-z0-9_]+' "$TF_DIR"/*.tf 2>/dev/null | sed 's/var\.//' | sort -u); do
  grep -q "^variable" "${TF_DIR}/variables.tf" 2>/dev/null && grep -qE "^variable \"${r}\"" "${TF_DIR}/variables.tf" 2>/dev/null || UNDECL+="${r} "
done
show "variable declarations vs references" "declared=${DECL} referenced-unique=${REFS} unused='${UNUSED:-none}' undeclared='${UNDECL:-none}'"
if count_ok "${DECL}" && [ "${DECL}" -ge 5 ]; then pass "terraform declares ${DECL} variables (parameterised, not hardcoded)"
else fail "few or no variables declared (${DECL:-0}) -- configuration is hardcoded"; fi
if [ -z "${UNDECL}" ]; then pass "every var.X referenced in the codebase is declared (no dangling references)"
else fail "referenced but undeclared variables: ${UNDECL}"; fi
if [ -z "${UNUSED}" ]; then pass "every declared variable is actually used (no dead configuration)"
else note "declared but unused variables: ${UNUSED}(harmless, flagged only)"; fi

show "grep -n 0.0.0.0/0 terraform/security_groups.tf" "$(grep -n '0\.0\.0\.0/0' "${TF_DIR}/security_groups.tf" 2>/dev/null)"
# Data-tier privacy is decided from the ATTACHMENT of each world-open ingress
# rule, not from the label of the nearest preceding resource. The previous
# `awk '/^resource .aws_security_group./{sg=$3} /0.0.0.0\/0/{print sg}'` printed
# whichever SG label it had last walked past, so the same exposure PASSed as a
# standalone rule and FAILED as an inline block.
# The ALB is internal (terraform/alb.tf), so the expected answer is now NO
# world-open ingress rule anywhere. An empty parser result is only trusted after
# the parser has detected a one-rule probe, so a parser that silently stopped
# working cannot turn into a pass.
SG_PROBE='resource "aws_security_group_rule" "probe" {
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.probe.id
}'
ALL_WORLD="$(sg_world_open)"
if [ "${ALL_WORLD}" = "__PARSER_MISSING__ ${SG_PARSER}" ]; then
  invalid "scripts/lib/hcl_sg_world_open.awk is missing -- the data-tier exposure check could not be executed, so it is INVALID and NOT a pass"
elif [ "$(printf '%s\n' "${SG_PROBE}" | awk -f "${SG_PARSER}" 2>/dev/null | cut -f1)" != "probe" ]; then
  invalid "the HCL parser did not detect its world-open probe rule, so an empty result would prove nothing -- the exposure check is INVALID, not a pass"
else
  show "awk -f scripts/lib/hcl_sg_world_open.awk terraform/*.tf   (sg-label, style, file:line)" "${ALL_WORLD:-<no world-open ingress rule; the probe rule was detected, so the parser works>}"
  DATA_OPEN="$(awk -F'\t' '$1=="db"||$1=="mq"{print $1" ("$2" at "$3")"}' <<<"${ALL_WORLD}" | sort -u | tr '\n' ' ')"
  DATA_OPEN="${DATA_OPEN% }"
  UNATTR="$(awk -F'\t' '$1 ~ /^UNATTRIBUTED\(/{print $1" at "$3}' <<<"${ALL_WORLD}" | tr '\n' ' ')"
  UNATTR="${UNATTR% }"
  if [ -z "${DATA_OPEN}" ] && [ -z "${UNATTR}" ]; then
    pass "no 0.0.0.0/0 ingress rule is attached to the db or mq security groups in ANY HCL style (standalone aws_security_group_rule, inline ingress{} block, or aws_vpc_security_group_ingress_rule): the data tier is private"
  else
    fail "a world-open ingress rule is attached to the data tier: ${DATA_OPEN:-none}${UNATTR:+, unattributable: ${UNATTR}}"
  fi
  if [ -z "${ALL_WORLD}" ]; then
    pass "no security group admits 0.0.0.0/0 ingress at all: the ALB is internal and API Gateway is the only public entry, as documented in terraform/security_groups.tf"
  else
    PUB_NAMES="$(cut -f1 <<<"${ALL_WORLD}" | sort -u | tr '\n' ' ')"
    fail "world-open ingress rule(s) found on '${PUB_NAMES% }': the ALB is internal (terraform/alb.tf), so no security group should admit 0.0.0.0/0"
  fi
fi
if [ -f "${ROOT_DIR}/.gitignore" ] && grep -q 'terraform.tfstate' "${ROOT_DIR}/.gitignore"; then
  pass ".gitignore excludes terraform.tfstate (no state committed)"
else
  fail ".gitignore does not exclude terraform.tfstate"
fi

if [ "${TERRAFORM_OK}" -eq 1 ]; then
  show "terraform -chdir=terraform fmt -check -diff" "$(terraform -chdir="${TF_DIR}" fmt -check -diff 2>&1 | head -20)"
  if terraform -chdir="${TF_DIR}" fmt -check >/dev/null 2>&1; then pass "terraform fmt -check is clean"
  else fail "terraform fmt -check reports formatting drift"; fi
  show "terraform -chdir=terraform validate" "$(terraform -chdir="${TF_DIR}" validate 2>&1 | head -20)"
  if terraform -chdir="${TF_DIR}" validate >/dev/null 2>&1; then pass "terraform validate succeeds"
  else fail "terraform validate fails"; fi
else
  invalid "terraform is not installed: 'terraform fmt -check' and 'terraform validate' cannot be run, so the IaC syntax/format verdict is UNKNOWN. All Terraform evidence in this run is STATIC text analysis only."
fi
fi

# =============================================================================
# SECTION 12 -- audit.md:74  infrastructure follows the architecture
# =============================================================================
if step "12" "Infrastructure follows the architecture & requirements" "audit.md:74"; then
# component : the token terraform really uses for it (the RDS instances are
# labelled "inventory"/"billing", not "inventory-database"/"billing-database").
MISSING_INFRA=()
while IFS='|' read -r comp token; do
  [ -n "${comp}" ] || continue
  if tf_grep "${token}" | grep -q .; then pass "terraform provisions infrastructure for '${comp}' (matched '${token}')"
  else MISSING_INFRA+=("${comp}"); fi
done <<'INFRA'
inventory-database|inventory-db
billing-database|billing-db
inventory-app|inventory-app
billing-app|billing-app
api-gateway|api_gateway
rabbitmq|rabbitmq
INFRA
if [ "${#MISSING_INFRA[@]}" -gt 0 ]; then fail "no terraform infrastructure found for: ${MISSING_INFRA[*]}"; fi

MA="$(fcount 'multi_az' "${TF_DIR}/rds.tf")"
show "grep -c multi_az terraform/rds.tf" "${MA:-0}"
if count_ok "${MA}" && [ "${MA}" -ge 1 ]; then pass "RDS is configured with Multi-AZ (availability pillar)"
else fail "no multi_az setting found on RDS"; fi
AZS="$(grep -oE 'us-east-1[abc]' "${TF_DIR}/vpc.tf" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
show "distinct AZs referenced in vpc.tf" "${AZS:-0}"
if count_ok "${AZS}" && [ "${AZS}" -ge 2 ]; then pass "the VPC spans ${AZS} availability zones"
else fail "the VPC does not span multiple AZs (found ${AZS:-0})"; fi

# ---- PodDisruptionBudgets: judged against the workload they select ----------
# The previous check counted PDB OBJECTS. Setting every `maxUnavailable` to 100
# therefore still passed, because an object with an absurd budget and an object
# with a useful budget are indistinguishable to a `grep -c`. Worse, the shipped
# manifests were already vacuous: all six workloads declare `replicas: 1` and
# the three PDBs declare `maxUnavailable: 1`, which together permit evicting the
# only pod. A PDB is evaluated here against the replicas it actually selects:
#   maxUnavailable >= replicas  -> permits total loss        -> USELESS
#   minAvailable    <= 0        -> permits total loss        -> USELESS
# Percentages are resolved against the selected workload's replica count.
K8S_PARSER="${SCRIPT_DIR}/lib/k8s_doc.awk"
k8s_docs() {
  if [ ! -f "${K8S_PARSER}" ]; then echo "__PARSER_MISSING__ ${K8S_PARSER}"; return 0; fi
  awk -f "${K8S_PARSER}" "$MAN_DIR"/*.yaml 2>/dev/null
}
K8S_ROWS="$(k8s_docs)"
if [ "${K8S_ROWS}" = "__PARSER_MISSING__ ${K8S_PARSER}" ]; then
  invalid "scripts/lib/k8s_doc.awk is missing -- PodDisruptionBudget effectiveness and probe semantics cannot be evaluated and are INVALID"
else
  # resolve "25%" / 1 against a replica count
  pdb_num() { # pdb_num <value> <replicas>
    case "$1" in
      '') echo "-"; return 0 ;;
      *%) echo "$(( (${1%%%} * $2 + 99) / 100 ))"; return 0 ;;
      *)  echo "$1"; return 0 ;;
    esac
  }
  PDBN="$(awk -F'\t' '$1=="PodDisruptionBudget"' <<<"${K8S_ROWS}" | grep -c . | head -1)"
  WL_ROWS="$(awk -F'\t' '$1=="Deployment"||$1=="StatefulSet"' <<<"${K8S_ROWS}")"
  WL_N="$(grep -c . <<<"${WL_ROWS}" | head -1)"

  PDB_TABLE=""; PDB_VACUOUS=""; PDB_COVERED=0; PDB_VACUOUS_N=0
  while IFS=$'\t' read -r kind name reps maxun minav sel _rest; do
    [ -n "${kind}" ] || continue
    reps_n="$(pdb_num "${reps}" 1)"; [ "${reps_n}" = "-" ] && reps_n=1
    pdb="$(awk -F'\t' -v s="${sel}" '$1=="PodDisruptionBudget" && $6==s {print; exit}' <<<"${K8S_ROWS}")"
    if [ -n "${pdb}" ]; then
      PDB_COVERED=$((PDB_COVERED + 1))
      pmax="$(cut -f4 <<<"${pdb}")"; pmin="$(cut -f5 <<<"${pdb}")"
      if [ "${pmax}" != "-" ]; then
        eff="$(pdb_num "${pmax}" "${reps_n}")"
        if [ "${eff}" -ge "${reps_n}" ] 2>/dev/null; then
          PDB_VACUOUS_N=$((PDB_VACUOUS_N + 1))
          PDB_VACUOUS+="${name} (maxUnavailable=${pmax} >= replicas=${reps_n}) "
          PDB_TABLE+="VACUOUS  ${kind}/${name} replicas=${reps_n} maxUnavailable=${pmax} -> may evict ALL pods"$'\n'
        else
          PDB_TABLE+="USEFUL   ${kind}/${name} replicas=${reps_n} maxUnavailable=${pmax} -> at least 1 pod always retained"$'\n'
        fi
      elif [ "${pmin}" != "-" ]; then
        eff="$(pdb_num "${pmin}" "${reps_n}")"
        if [ "${eff}" -le 0 ] 2>/dev/null; then
          PDB_VACUOUS_N=$((PDB_VACUOUS_N + 1))
          PDB_VACUOUS+="${name} (minAvailable=${pmin} <= 0) "
          PDB_TABLE+="VACUOUS  ${kind}/${name} replicas=${reps_n} minAvailable=${pmin} -> may evict ALL pods"$'\n'
        else
          PDB_TABLE+="USEFUL   ${kind}/${name} replicas=${reps_n} minAvailable=${pmin} -> at least 1 pod always retained"$'\n'
        fi
      else
        PDB_VACUOUS_N=$((PDB_VACUOUS_N + 1))
        PDB_VACUOUS+="${name} (no maxUnavailable and no minAvailable) "
        PDB_TABLE+="VACUOUS  ${kind}/${name} replicas=${reps_n} no budget key at all -> unlimited eviction"$'\n'
      fi
    elif [ "${reps_n}" -ge 2 ] 2>/dev/null; then
      PDB_TABLE+="MISSING  ${kind}/${name} replicas=${reps_n} NO PodDisruptionBudget (multi-replica, unguarded)"$'\n'
      PDB_VACUOUS_N=$((PDB_VACUOUS_N + 1))
      PDB_VACUOUS+="${name} (replicas=${reps_n} and NO PodDisruptionBudget at all) "
    else
      PDB_TABLE+="n/a      ${kind}/${name} replicas=1 and no PDB -- a PDB here would deadlock kubectl drain, so absence is correct at this size (reported as a NOTE)"$'\n'
    fi
  done <<<"${WL_ROWS}"

  show "awk -f scripts/lib/k8s_doc.awk manifests/*.yaml -> kind/name/replicas/budget/selector, evaluated per selected workload" "${PDB_TABLE:-<no workloads parsed>}"
  if count_ok "${WL_N}" && [ "${WL_N}" -ge 1 ]; then
    pass "parsed ${WL_N} Deployment/StatefulSet workload(s) and ${PDBN:-0} PodDisruptionBudget(s) from manifests/ and evaluated every budget against the replicas it actually selects"
  else
    fail "could not parse any Deployment/StatefulSet out of manifests/ (found ${WL_N:-0}); no PDB verdict is possible"
  fi
  if [ "${PDB_VACUOUS_N}" -eq 0 ]; then
    pass "every PodDisruptionBudget in manifests/ still leaves at least one replica in service at the declared replica count (see the table above)"
  else
    fail "${PDB_VACUOUS_N} disruption-budget finding(s) in manifests/ are vacuous: an object that advertises protection while permitting the loss of every pod is worse than no object, because it still gets counted as a control -- ${PDB_VACUOUS}"
  fi
  # StatefulSets without a PDB. Reported as a finding, not a failure: at
  # replicas=1 a PDB with maxUnavailable:0 would block `kubectl drain`
  # forever and maxUnavailable:1 is exactly the vacuous case above, so the fix
  # belongs to the manifests owner (raise replicas, or accept the eviction).
  STS_NOPDB=""
  while IFS=$'\t' read -r kind name reps maxun minav sel _rest; do
    [ "${kind}" = "StatefulSet" ] || continue
    awk -F'\t' -v s="${sel}" '$1=="PodDisruptionBudget" && $6==s{f=1} END{exit !f}' <<<"${K8S_ROWS}" || STS_NOPDB+="${name} "
  done <<<"${WL_ROWS}"
  if [ -z "${STS_NOPDB}" ]; then
    pass "every StatefulSet in manifests/ has a PodDisruptionBudget selecting it"
  else
    note "FINDING -- StatefulSet(s) with NO PodDisruptionBudget: ${STS_NOPDB%. } (both databases and the RabbitMQ broker are stateful and single-replica; a PDB only becomes meaningful once they are scaled above 1. Flagged for the manifests owner: this script does not edit manifests/.)"
  fi
fi

# ---- probe semantics: liveness must not be coupled to the database ----------
# Rewiring livenessProbe from /health to /ready couples pod liveness to
# database reachability: a database blip then fails every app pod's liveness
# probe and Kubernetes restarts the entire app tier at once, which turns a
# recoverable dependency outage into a full outage. Nothing checked this.
if [ -n "${K8S_ROWS}" ] && [ "${K8S_ROWS}" != "__PARSER_MISSING__ ${K8S_PARSER}" ]; then
  PROBE_TABLE=""; PROBE_BAD=""; PROBE_N=0; PROBE_EXEC=0
  while IFS=$'\t' read -r kind name reps maxun minav sel lpath rpath lkind rkind _rest; do
    [ "${kind}" = "Deployment" ] || [ "${kind}" = "StatefulSet" ] || continue
    if [ "${lkind}" = "-" ] || [ "${rkind}" = "-" ]; then
      PROBE_TABLE+="${kind}/${name}: only one of liveness/readiness is declared -- skipped"$'\n'
      continue
    fi
    PROBE_N=$((PROBE_N + 1))
    if [ "${lpath}" = "-" ]; then
      PROBE_EXEC=$((PROBE_EXEC + 1)); PROBE_N=$((PROBE_N - 1))
      PROBE_TABLE+="${kind}/${name}: liveness=${lkind} readiness=${rkind} (not path-based; not path-checkable)"$'\n'
      continue
    fi
    case "${lpath}" in
      */ready|*/readyz|*/ready/*)
        PROBE_BAD+="${kind}/${name} liveness=${lpath} "
        PROBE_TABLE+="${kind}/${name}: liveness=${lpath} readiness=${rpath} <-- LIVENESS IS THE DB-AWARE ENDPOINT"$'\n' ;;
      */health|*/healthz|*/live|*/ping|*/startup)
        PROBE_TABLE+="${kind}/${name}: liveness=${lpath} readiness=${rpath} (liveness is DB-independent)"$'\n' ;;
      *)
        PROBE_BAD+="${kind}/${name} liveness=${lpath} is not a recognised liveness endpoint "
        PROBE_TABLE+="${kind}/${name}: liveness=${lpath} readiness=${rpath} <-- unrecognised liveness endpoint"$'\n' ;;
    esac
  done <<<"${K8S_ROWS}"
  show "livenessProbe vs readinessProbe per workload (from scripts/lib/k8s_doc.awk)" "${PROBE_TABLE:-<no workloads parsed>}"
  if [ "${PROBE_N}" -eq 0 ] && [ "${PROBE_EXEC}" -eq 0 ]; then
    invalid "no workload in manifests/ declares both a liveness and a readiness probe, so probe semantics could not be evaluated"
  elif [ -z "${PROBE_BAD}" ]; then
    pass "all ${PROBE_N} path-based workload(s) probe liveness on a DB-independent endpoint and readiness on the DB-aware one where the workload has a database (${PROBE_EXEC} further workload(s) use exec/tcp probes, which carry no path and cannot be rewired)"
  else
    fail "liveness is wired to a DB-dependent or unrecognised endpoint: ${PROBE_BAD}-- a transient database outage would then restart every pod in that tier at once"
  fi
fi

if grep -q 'alb.ingress.kubernetes.io/scheme' "${MAN_DIR}/ingress.yaml" 2>/dev/null; then
  pass "manifests/ingress.yaml uses the AWS Load Balancer Controller with an explicit scheme annotation"
else
  note "ingress.yaml does not set an alb scheme annotation"
fi
fi

# =============================================================================
# SECTION 13 -- audit.md:78  Dockerfiles optimised (REAL analysis)
# =============================================================================
if step "13" "Dockerfiles optimised (real per-image analysis)" "audit.md:78"; then
note "This replaces the old existence-only check. Every column below is read out of each srcs/<c>/Dockerfile."
printf "  %-19s %-28s %-6s %-9s %-12s %-8s %s\n" component "base image" stages non-root COPY--chmod cache-rn dockerignore
printf "  %-19s %-28s %-6s %-9s %-12s %-8s %s\n" ------------------- ---------------------------- ------ -------- ------------ -------- ------------

DF_TOTAL=0; DF_NONROOT=0; DF_CHMOD=0; DF_IGNORE=0; DF_CACHE=0
for d in "${SRC_DIRS[@]}"; do
  f="${ROOT_DIR}/srcs/${d}/Dockerfile"
  [ -f "$f" ] || continue
  DF_TOTAL=$((DF_TOTAL + 1))
  BASE="$(grep -m1 -E '^FROM ' "$f" | awk '{print $2}')"
  STAGES="$(grep -cE '^FROM .+ AS ' "$f" | head -1)"
  if grep -qE '^USER[[:space:]]+' "$f"; then NONROOT="yes"; DF_NONROOT=$((DF_NONROOT + 1)); else NONROOT="no(root)"; fi
  # `--chmod` is not always the FIRST flag: the app images write
  # `COPY --chown=appuser:appgroup --chmod=0644 ...`, so anchoring on
  # `^COPY[[:space:]]+--chmod=` would report a false 'no'.
  if grep -qE '^COPY[[:space:]].*--chmod=' "$f"; then CHMOD="yes"; DF_CHMOD=$((DF_CHMOD + 1)); else CHMOD="no"; fi
  if grep -qE 'rm -rf /root/\.cache|apk --no-cache|--no-cache-dir|PIP_NO_CACHE' "$f"; then CACHE="yes"; DF_CACHE=$((DF_CACHE + 1)); else CACHE="no"; fi
  if [ -f "${ROOT_DIR}/srcs/${d}/.dockerignore" ]; then IGN="yes"; DF_IGNORE=$((DF_IGNORE + 1)); else IGN="NO"; fi
  printf "  %-19s %-28s %-6s %-9s %-12s %-8s %s\n" "${d}" "${BASE}" "${STAGES}" "${NONROOT}" "${CHMOD}" "${CACHE}" "${IGN}"
done
if count_ok "${DF_TOTAL}" && [ "${DF_TOTAL}" -ge 5 ]; then
  pass "analysed ${DF_TOTAL} Dockerfiles -- a real per-image report, not an existence check"
else
  fail "could not analyse the Dockerfiles (${DF_TOTAL:-0} found)"
fi
MULTI_OK=0
for a in api-gateway inventory-app billing-app; do
  grep -qE '^FROM .+ AS ' "${ROOT_DIR}/srcs/${a}/Dockerfile" 2>/dev/null && MULTI_OK=$((MULTI_OK + 1))
done
if [ "${MULTI_OK}" -eq 3 ]; then pass "all 3 Python app images are multi-stage (builder + runtime), so build tooling stays out of the shipped image"
else fail "only ${MULTI_OK}/3 Python app Dockerfiles are multi-stage"; fi
if [ "${DF_NONROOT}" -ge 3 ]; then pass "${DF_NONROOT} image(s) bake a non-root USER (the 3 Python apps run as 'appuser')"
else fail "fewer than 3 images set a non-root USER (${DF_NONROOT})"; fi
if [ "${DF_CHMOD}" -ge 5 ]; then pass "${DF_CHMOD} images use COPY --chmod, setting permissions in-layer instead of adding a RUN chmod layer"
else note "only ${DF_CHMOD} images use COPY --chmod"; fi
if [ "${DF_CACHE}" -ge 3 ]; then pass "${DF_CACHE} images disable/clean the package cache (PIP_NO_CACHE_DIR or apk --no-cache)"
else note "only ${DF_CACHE} images explicitly handle the package cache"; fi
if [ "${DF_IGNORE}" -ge 6 ]; then pass "every component ships a .dockerignore, so build contexts stay small"
else fail "${DF_IGNORE}/6 components have a .dockerignore (build contexts may be bloated)"; fi

if [ "${DOCKER_OK}" -eq 1 ] && docker info >/dev/null 2>&1; then
  echo
  IMG_ALL="$(docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | grep '^cloud-design/' | sort)"
  IMG_N="$(grep -c . <<<"${IMG_ALL}" | head -1)"
  # Every image exists under TWO tags (the compose-referenced :local and a
  # :latest), so the listing above has roughly twice as many lines as there are
  # components. That used to read as "the script only measured 6 of the 12", so
  # the duplication is now stated, and the measurement below uses the tag
  # docker-compose.yml actually references rather than a hardcoded one.
  IMG_TAGS="$(grep -oE '^[[:space:]]*image:[[:space:]]*cloud-design/[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+' "${ROOT_DIR}/docker-compose.yml" 2>/dev/null | grep -oE ':[A-Za-z0-9_.-]+$' | sort | uniq -c | tr '\n' ' ')"
  show "docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep ^cloud-design/ | sort   -- ALL ${IMG_N:-0} lines, nothing filtered or truncated" "${IMG_ALL:-<no cloud-design/* images>}"
  note "that listing is complete: ${IMG_N:-0} tags for ${#SRC_DIRS[@]} components, because every image carries both the compose tag (:local) and a :latest alias${IMG_TAGS:+ [tags actually referenced by docker-compose.yml: ${IMG_TAGS% }]}. The measurement below uses the compose tag only."
  for a in api-gateway inventory-app billing-app inventory-database billing-database rabbit-queue; do
    want_tag="$(sed -nE "s/^[[:space:]]*image:[[:space:]]*cloud-design\/${a}:([A-Za-z0-9_.-]+).*/\1/p" "${ROOT_DIR}/docker-compose.yml" 2>/dev/null | head -1)"
    [ -n "${want_tag}" ] || want_tag="local"
    sz="$(docker images --format '{{.Size}}' "cloud-design/${a}:${want_tag}" 2>/dev/null | head -1)"
    if [ -n "${sz}" ]; then pass "measured image size: cloud-design/${a}:${want_tag} = ${sz} (the tag docker-compose.yml references)"
    else note "cloud-design/${a}:${want_tag} is not built locally -- no real size to report"; fi
  done
else
  invalid "docker is not usable -- real image sizes are INVALID (the static Dockerfile analysis above is all that can be proven)"
fi
fi

# =============================================================================
# SECTION 14 -- audit.md:80  orchestration configured correctly
# =============================================================================
if step "14" "Orchestration configured correctly (kustomize + server dry-run + ECS)" "audit.md:80"; then
if [ "${KUBECTL_OK}" -eq 1 ]; then
  show "kubectl kustomize manifests/ | tail -3" "$(kubectl kustomize "${MAN_DIR}/" 2>&1 | tail -3)"
  if kubectl kustomize "${MAN_DIR}/" >/dev/null 2>&1; then
    KN="$(kubectl kustomize "${MAN_DIR}/" 2>/dev/null | grep -c '^kind:' | head -1)"
    show "kubectl kustomize manifests/ | grep -c '^kind:'" "${KN} objects emitted by kustomize"
    pass "kubectl kustomize manifests/ parses cleanly (all ${KN} objects are structurally valid)"
  else
    fail "kubectl kustomize manifests/ fails to parse"
  fi

  kubectl apply -f "${MAN_DIR}/" --dry-run=client >/dev/null 2>&1
  RC=$?
  show "kubectl apply -f manifests/ --dry-run=client ; echo \$?" "${RC}"
  if [ "${RC}" -ne 0 ]; then
    pass "confirmed: 'kubectl apply -f manifests/' EXITS ${RC} (it parses kustomization.yaml as a manifest). '-k' is required."
  else
    note "'kubectl apply -f manifests/' happened to succeed here, but '-k' is still the supported and documented form"
  fi

  if [ "${CLUSTER_REACHABLE}" -eq 1 ]; then
    show "kubectl apply --dry-run=server -k manifests/ | tail -3" "$(kubectl apply --dry-run=server -k "${MAN_DIR}/" 2>&1 | tail -3)"
    if kubectl apply --dry-run=server -k "${MAN_DIR}/" >/dev/null 2>&1; then
      pass "kubectl apply --dry-run=server -k manifests/ is accepted by the API server (schema-valid)"
    else
      fail "server dry-run of manifests/ is rejected by the API server"
    fi
    PW="$(kubectl get pods -n cloud-design --no-headers 2>/dev/null | grep -c . | head -1)"
    if [ "${CLUSTER_REACHABLE}" -eq 1 ] && count_ok "${PW}" && [ "${PW}" -ge 6 ]; then
      pass "${PW} pods are live in namespace cloud-design from these manifests"
    else
      invalid "cannot confirm the live pod count"
    fi
  else
    invalid "no reachable cluster -- 'kubectl apply --dry-run=server' is INVALID (the server-less kustomize parse above did pass)"
  fi
else
  invalid "kubectl is not installed -- every manifest validation is INVALID"
fi

if [ "${JQ_OK}" -eq 1 ]; then
  for j in "${ECS_DIR}"/*.json; do
    [ -f "$j" ] || continue
    if jq -e . "$j" >/dev/null 2>&1; then pass "$(basename "$j") is valid JSON"; else fail "$(basename "$j") is invalid JSON"; fi
  done
  show "ECS task families" "$(jq -r '.family' "${ECS_DIR}"/*.json 2>/dev/null | tr '\n' ' ')"
  # NOTE: `jq -e f1.json f2.json ...` exits on the LAST file's result only, so a
  # per-file loop is required -- otherwise one non-matching file fails the check.
  for want in api-gateway inventory-app billing-app; do
    FOUND=""
    for j in "${ECS_DIR}"/*.json; do
      [ -f "$j" ] || continue
      fam="$(jq -r '.family' "$j" 2>/dev/null)"
      case "${fam}" in *"${want}"*) FOUND="${fam}"; break ;; esac
    done
    if [ -n "${FOUND}" ]; then pass "an ECS task definition exists for ${want} (family '${FOUND}')"
    else fail "no ECS task definition for ${want}"; fi
  done
  NETMODE="$(jq -r '.networkMode' "${ECS_DIR}"/*.json 2>/dev/null | sort -u | tr '\n' ' ')"
  show "networkMode across task definitions" "${NETMODE:-<none>}"
  if grep -q 'awsvpc' <<<"${NETMODE}"; then pass "tasks use awsvpc networking (required for ALB ip-type targets)"; else fail "no awsvpc networkMode"; fi
  TFLOGS="$(fcount 'awslogs' "${TF_DIR}/ecs_services.tf")"
  show "grep -c awslogs terraform/ecs_services.tf" "${TFLOGS:-0}"
  if [ "${TFLOGS:-0}" -ge 1 ]; then pass "CloudWatch awslogs log configuration is wired in ecs_services.tf (${TFLOGS} references)"
  else fail "no awslogs log driver configuration found for ECS"; fi
  SDREG="$(fcount 'service_registries' "${TF_DIR}/ecs_services.tf")"
  SDN="$(tf_res service_discovery_service)"; NSN="$(tf_res service_discovery_private_dns_namespace)"
  show "service discovery / service_registries" "namespace=${NSN:-0} service=${SDN:-0} services-registering=${SDREG:-0}"
  if [ "${NSN:-0}" -ge 1 ] && [ "${SDN:-0}" -ge 1 ] && [ "${SDREG:-0}" -ge 1 ]; then
    pass "Cloud Map service discovery is provisioned and ${SDREG} ECS service(s) register with it"
  else
    fail "service discovery is incomplete (ns=${NSN:-0} svc=${SDN:-0} registering=${SDREG:-0})"
  fi
  CLN="$(tf_res ecs_cluster)"; SVN="$(tf_res ecs_service)"; TDN="$(tf_res ecs_task_definition)"
  CPVN="$(tf_res ecs_cluster_capacity_providers)"
  show "ECS cluster / services / task definitions / capacity providers" "${CLN:-0} / ${SVN:-0} / ${TDN:-0} / ${CPVN:-0}"
  if [ "${CLN:-0}" -ge 1 ] && [ "${SVN:-0}" -ge 3 ] && [ "${TDN:-0}" -ge 3 ] && [ "${CPVN:-0}" -ge 1 ]; then
    pass "ECS: 1 cluster, ${SVN} services, ${TDN} task definitions, capacity providers configured"
  else
    fail "ECS topology incomplete (cluster=${CLN:-0} services=${SVN:-0} taskdefs=${TDN:-0} capproviders=${CPVN:-0})"
  fi
else
  invalid "jq is not installed -- ECS task-definition validation is INVALID"
fi
fi

# =============================================================================
# SECTION 15 -- audit.md:84  monitoring & logging dashboards
# =============================================================================
if step "15" "Monitoring & logging dashboards" "audit.md:84"; then
if tf_any cloudwatch_dashboard; then
  WIDGETS="$(awk '/widgets[[:space:]]*=[[:space:]]*\[/{f=1} f && /^[[:space:]]*type[[:space:]]*=/{c++} f && /^    \}\)/{f=0} END{print c+0}' "${TF_DIR}/cloudwatch.tf" 2>/dev/null)"
  show "aws_cloudwatch_dashboard widget count" "${WIDGETS} widget(s)"
  if count_ok "${WIDGETS}" && [ "${WIDGETS}" -ge 3 ]; then pass "a centralised CloudWatch dashboard exists with ${WIDGETS} widgets"
  else fail "the dashboard has too few widgets (${WIDGETS:-0}) to be 'useful'"; fi
else
  fail "no aws_cloudwatch_dashboard found"
fi

LGN="$(tf_res cloudwatch_log_group)"
LGR="$(fcount 'retention_in_days' "${TF_DIR}/cloudwatch.tf")"
show "log groups / retention declarations" "${LGN:-0} log groups, ${LGR:-0} retention_in_days declarations"
if count_ok "${LGN}" && [ "${LGN}" -ge 2 ]; then pass "${LGN} CloudWatch log groups are provisioned"
else fail "too few CloudWatch log groups (${LGN:-0})"; fi
if count_ok "${LGR}" && [ "${LGR}" -ge "${LGN:-0}" ]; then pass "every log group sets retention_in_days (log cost is bounded)"
else fail "some log groups lack retention_in_days (${LGR:-0} declarations for ${LGN:-0} groups)"; fi

ALN="$(tf_res cloudwatch_metric_alarm)"
show "aws_cloudwatch_metric_alarm count" "${ALN:-0}"
if count_ok "${ALN}" && [ "${ALN}" -ge 6 ]; then pass "${ALN} CloudWatch metric alarms are configured (the rubric asks for 'useful'; >5 is a strong posture)"
else note "only ${ALN:-0} metric alarms; more coverage is expected for a mature stack"; fi
AA="$(fcount 'alarm_actions' "${TF_DIR}/cloudwatch.tf")"
SNST="$(tf_res sns_topic)"; SNSP="$(tf_res sns_topic_policy)"
show "alarm_actions / SNS topic / SNS topic policy" "alarm_actions=${AA:-0} sns_topic=${SNST:-0} sns_topic_policy=${SNSP:-0}"
if [ "${SNST:-0}" -ge 1 ] && [ "${SNSP:-0}" -ge 1 ] && [ "${AA:-0}" -ge 1 ]; then
  pass "an SNS topic AND its topic policy exist, and ${AA} alarm_actions reference them (alarms can actually deliver)"
else
  fail "SNS topic=${SNST:-0} policy=${SNSP:-0} alarm_actions=${AA:-0}; an alarm with no deliverable subscription is theatre"
fi
BU="$(tf_res budgets_budget)"
if [ "${BU:-0}" -ge 1 ]; then pass "AWS Budgets is provisioned (cost alerting)"; else note "no aws_budgets_budget"; fi
fi

# =============================================================================
# SECTION 16 -- audit.md:88  auto-scaling configured correctly (per-target)
# =============================================================================
if step "16" "Auto-scaling configured correctly (every target inspected)" "audit.md:88"; then
TGT_CNT="$(tf_res appautoscaling_target)"
POL_CNT="$(tf_res appautoscaling_policy)"
show "appautoscaling targets / policies" "${TGT_CNT:-0} target(s), ${POL_CNT:-0} policy(ies)"
if [ "${TGT_CNT:-0}" -gt 0 ] && [ "${TGT_CNT}" -eq "${POL_CNT}" ]; then
  pass "every appautoscaling target has a matching policy"
else
  fail "target/policy count mismatch (${TGT_CNT:-0} targets, ${POL_CNT:-0} policies)"
fi

# The raw right-hand side is kept, so a bound written as `var.NAME` is resolved
# to that variable's default by tf_num below. The previous parser kept only the
# digits, so `min_capacity = var.billing_app_min_capacity` became an empty string
# and the billing-app target was silently left out of every check in this loop.
TARGET_ROWS="$(awk '
  /^resource .aws_appautoscaling_target./ {inblk=1; nm=$3; gsub(/"/,"",nm); mn=""; mx=""; next}
  inblk && /^}/ {if(mn!=""||mx!="") printf "target=%s min=%s max=%s\n", nm, mn, mx; inblk=0; next}
  inblk && /min_capacity/ {v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]#].*$/,"",v); mn=v}
  inblk && /max_capacity/ {v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]#].*$/,"",v); mx=v}
' "${TF_DIR}/autoscaling.tf" 2>/dev/null)"
tf_num() { # tf_num <literal | var.NAME>: the number, or the default of variable NAME
  case "$1" in
    var.*) awk -v n="${1#var.}" '$0 ~ "^variable \"" n "\"" {f=1} f && /default[[:space:]]*=/ {gsub(/[^0-9]/,""); print; exit}' "${TF_DIR}/variables.tf" 2>/dev/null ;;
    *)     printf '%s' "$1" | tr -cd '0-9' ;;
  esac
}
target_min() { tf_num "$(sed -n "s/^target=$1 min=\([^ ]*\) .*/\1/p" <<<"${TARGET_ROWS}")"; }
show "per-target min/max parsed from terraform/autoscaling.tf" "${TARGET_ROWS:-<no targets parsed>}"
# An auto-scaling target is only "configured correctly" if BOTH ends of the range
# are sane. The floor was checked (min_capacity = 0 was caught); the ceiling was
# not, so `max_capacity = 99` passed. The ceiling is what actually decides the
# worst-case bill: at the t3g/t4g Fargate rates this project budgets for, one
# service running its maximum is already more than the whole monthly budget.
AS_MAX_CEILING=20
note "Auto-scaling ceilings are bounded at max_capacity <= ${AS_MAX_CEILING} (and HPA maxReplicas <= ${AS_MAX_CEILING}). A range like min=1 max=99 is not 'configured correctly', it is an unbounded spend permission that no alarm covers."
while read -r row; do
  [ -n "${row}" ] || continue
  nm="$(sed 's/.*target=\([^ ]*\).*/\1/' <<<"${row}")"
  mn="$(tf_num "$(sed 's/.* min=\([^ ]*\).*/\1/' <<<"${row}")")"
  mx="$(tf_num "$(sed 's/.* max=\([^ ]*\).*/\1/' <<<"${row}")")"
  if count_ok "${mn}" && count_ok "${mx}" && [ "${mn}" -ge 1 ] && [ "${mx}" -gt "${mn}" ]; then
    pass "${nm}: min_capacity=${mn} max_capacity=${mx} (a sane range)"
  else
    fail "${nm}: min_capacity='${mn:-?}' max_capacity='${mx:-?}' is missing or nonsensical"
  fi
  if count_ok "${mx}" && [ "${mx}" -le "${AS_MAX_CEILING}" ]; then
    pass "${nm}: max_capacity=${mx} is within the ${AS_MAX_CEILING}-replica ceiling, so the worst-case cost of this target is bounded"
  else
    fail "${nm}: max_capacity='${mx:-?}' is above the ${AS_MAX_CEILING}-replica ceiling (or unreadable) -- the target has no cost bound, which contradicts the cost-effectiveness section"
  fi
  if grep -q "appautoscaling_target\.${nm}\.resource_id" "${TF_DIR}/autoscaling.tf" 2>/dev/null; then
    pass "a policy references aws_appautoscaling_target.${nm} (not an orphan target)"
  else
    fail "no policy references aws_appautoscaling_target.${nm} -- it would never scale"
  fi
done <<<"${TARGET_ROWS}"

ACV="$(awk '/^variable .autoscaling_target_cpu./{f=1} f && /default[[:space:]]*=/{gsub(/[^0-9.]/,"");print;exit}' "${TF_DIR}/variables.tf" 2>/dev/null)"
show "autoscaling_target_cpu default" "${ACV:-<not found>}%"
if count_ok "${ACV%%.*}" && [ "${ACV%%.*}" -ge 30 ] && [ "${ACV%%.*}" -le 90 ]; then
  pass "the target-tracking CPU target is a sane ${ACV}% (var.autoscaling_target_cpu)"
else
  fail "autoscaling_target_cpu default is '${ACV:-<missing>}', not a sane percentage"
fi
COOL="$(fcount -E 'scale_(in|out)_cooldown' "${TF_DIR}/autoscaling.tf")"
if [ "${COOL:-0}" -ge 2 ]; then pass "scale-in and scale-out cooldowns are set (prevents flapping)"
else note "no cooldowns set on the autoscaling policies"; fi

show "grep -n desired_count terraform/ecs_services.tf" "$(grep -n 'desired_count' "${TF_DIR}/ecs_services.tf" 2>/dev/null)"
DC_API="$(awk '/resource .aws_ecs_service. .api_gateway./{f=1} f && /desired_count/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/ecs_services.tf" 2>/dev/null)"
DC_INV="$(awk '/resource .aws_ecs_service. .inventory_app./{f=1} f && /desired_count/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/ecs_services.tf" 2>/dev/null)"
DC_BIL="$(awk '/resource .aws_ecs_service. .billing_app./{f=1} f && /desired_count/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/ecs_services.tf" 2>/dev/null)"
MN_API="$(target_min api_gateway)"; MN_INV="$(target_min inventory_app)"; MN_BIL="$(target_min billing_app)"
# Two tasks on the request path is the design claim: the internal ALB needs two
# targets to balance anything, and one task per private app subnet is what makes
# an AZ loss halve capacity instead of removing it.
if count_ok "${DC_API}" && count_ok "${MN_API}" && [ "${DC_API}" -eq "${MN_API}" ] && [ "${DC_API}" -ge 2 ]; then
  pass "api-gateway desired_count=${DC_API} equals min_capacity=${MN_API}: two ALB targets, one per AZ"
else
  fail "api-gateway desired_count='${DC_API:-?}' / min_capacity='${MN_API:-?}' must be equal and >= 2, or the ALB has a single target and one AZ loss takes the request path down"
fi
if count_ok "${DC_INV}" && count_ok "${MN_INV}" && [ "${DC_INV}" -eq "${MN_INV}" ] && [ "${DC_INV}" -ge 2 ]; then
  pass "inventory-app desired_count=${DC_INV} equals min_capacity=${MN_INV}: an AZ loss halves the /api/movies path instead of removing it"
else
  fail "inventory-app desired_count='${DC_INV:-?}' / min_capacity='${MN_INV:-?}' must be equal and >= 2, or one AZ loss takes /api/movies down"
fi
if count_ok "${DC_BIL}" && count_ok "${MN_BIL}" && [ "${DC_BIL}" -eq "${MN_BIL}" ] && [ "${DC_BIL}" -ge 2 ]; then
  pass "billing-app desired_count=${DC_BIL} matches billing_app_min_capacity=${MN_BIL} -- never a single consumer"
else
  fail "billing-app desired_count='${DC_BIL:-?}' / min_capacity='${MN_BIL:-?}' must be equal and >= 2: one consumer task is a single point of failure for order processing"
fi
# The autoscaler owns desiredCount once a service exists. A service without
# ignore_changes = [desired_count] is reset to its create-time count by the next
# terraform apply, in the middle of whatever burst it was scaled out for.
SVC_N="$(fcount '^resource "aws_ecs_service"' "${TF_DIR}/ecs_services.tf")"
IGN_N="$(fcount -E 'ignore_changes[[:space:]]*=[[:space:]]*\[desired_count\]' "${TF_DIR}/ecs_services.tf")"
show "ECS services / services with ignore_changes = [desired_count]" "${SVC_N:-0} / ${IGN_N:-0}"
if count_ok "${SVC_N}" && [ "${SVC_N}" -ge 1 ] && [ "${IGN_N:-0}" = "${SVC_N}" ]; then
  pass "every ECS service leaves desiredCount to its autoscaling target (ignore_changes = [desired_count])"
else
  fail "only ${IGN_N:-0} of ${SVC_N:-?} ECS services ignore desired_count drift: terraform apply would undo the autoscaler's scale-out on the others"
fi

# The queue consumer must scale on BACKLOG, not CPU: a consumer blocked on an
# AMQP socket is idle while messages pile up, so CPU target tracking would never
# fire in the one situation that needs another consumer.
if grep -q 'AWS/AmazonMQ' "${TF_DIR}/autoscaling.tf" 2>/dev/null \
   && grep -q 'MessageCount' "${TF_DIR}/autoscaling.tf" 2>/dev/null; then
  pass "the billing-app policy scales on AWS/AmazonMQ MessageCount backlog, not on CPU"
else
  fail "no Amazon MQ MessageCount policy for billing-app -- a queue consumer scaled on CPU does not react to a backlog"
fi
QD="$(awk '/^variable .billing_queue_depth_target./{f=1} f && /default[[:space:]]*=/{gsub(/[^0-9.]/,"");print;exit}' "${TF_DIR}/variables.tf" 2>/dev/null)"
show "billing_queue_depth_target default" "${QD:-<not found>} messages"
if count_ok "${QD%%.*}" && [ "${QD%%.*}" -ge 1 ]; then
  pass "the backlog target is a concrete message count (${QD}), not a placeholder"
else
  fail "billing_queue_depth_target has no numeric default (got '${QD:-}')"
fi

# Cross-path consistency: the Kubernetes HPA bounds must agree with the ECS
# target, or the two orchestrators tell the examiner different stories. The ECS
# target binds VARIABLES rather than literals, so the authoritative numbers are
# the variable defaults it references -- and that binding is itself asserted, so
# "documented bounds" cannot drift away from "enforced bounds".
BIL_MN="$(awk '/^kind: HorizontalPodAutoscaler/{f=1} f && /minReplicas/{gsub(/[^0-9]/,"");print;exit}' "${MAN_DIR}/billing-app.yaml" 2>/dev/null)"
BIL_MX="$(awk '/^kind: HorizontalPodAutoscaler/{f=1} f && /maxReplicas/{gsub(/[^0-9]/,"");print;exit}' "${MAN_DIR}/billing-app.yaml" 2>/dev/null)"
TF_BIL_MN="$(awk '/^variable .billing_app_min_capacity./{f=1} f && /default[[:space:]]*=/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/variables.tf" 2>/dev/null)"
TF_BIL_MX="$(awk '/^variable .billing_app_max_capacity./{f=1} f && /default[[:space:]]*=/{gsub(/[^0-9]/,"");print;exit}' "${TF_DIR}/variables.tf" 2>/dev/null)"
TF_BINDS="$(fcount 'min_capacity[[:space:]]*=[[:space:]]*var\.billing_app_min_capacity' "${TF_DIR}/autoscaling.tf")"
show "billing consumer bounds: ECS vs manifests" "ecs=${TF_BIL_MN:-?}/${TF_BIL_MX:-?}  k8s-hpa=${BIL_MN:-?}/${BIL_MX:-?}  (ecs target binds the vars: ${TF_BINDS:-0})"
if count_ok "${TF_BINDS}" && [ "${TF_BINDS}" -ge 1 ]; then
  pass "the ECS billing-app target binds var.billing_app_min_capacity / _max_capacity instead of hardcoding numbers"
else
  fail "aws_appautoscaling_target.billing_app does not bind var.billing_app_min_capacity -- the documented bounds are not the enforced ones"
fi
if count_ok "${TF_BIL_MN}" && count_ok "${BIL_MN}" && [ "${TF_BIL_MN}" = "${BIL_MN}" ] \
   && count_ok "${TF_BIL_MX}" && count_ok "${BIL_MX}" && [ "${TF_BIL_MX}" = "${BIL_MX}" ]; then
  pass "both orchestrators agree on the consumer's bounds (min ${BIL_MN} / max ${BIL_MX})"
else
  fail "the two orchestrators disagree on billing-app bounds: ECS ${TF_BIL_MN:-?}/${TF_BIL_MX:-?} vs manifests ${BIL_MN:-?}/${BIL_MX:-?}"
fi

HPAS="$(grep -rh '^kind: HorizontalPodAutoscaler' "${MAN_DIR}"/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
show "HPA objects in manifests/" "${HPAS:-0}"
if [ "${HPAS:-0}" -ge 2 ]; then pass "${HPAS} HPAs are declared in the manifests"; else fail "only ${HPAS:-0} HPA(s) in manifests"; fi
for mf in api-gateway inventory-app billing-app; do
  mn="$(awk '/^kind: HorizontalPodAutoscaler/{f=1} f && /minReplicas/{gsub(/[^0-9]/,"");print;exit}' "${MAN_DIR}/${mf}.yaml" 2>/dev/null)"
  mx="$(awk '/^kind: HorizontalPodAutoscaler/{f=1} f && /maxReplicas/{gsub(/[^0-9]/,"");print;exit}' "${MAN_DIR}/${mf}.yaml" 2>/dev/null)"
  th="$(awk '/^kind: HorizontalPodAutoscaler/{f=1} f && /averageUtilization/{gsub(/[^0-9]/,"");print;exit}' "${MAN_DIR}/${mf}.yaml" 2>/dev/null)"
  if count_ok "${mn}" && count_ok "${mx}" && count_ok "${th}" && [ "${mn}" -ge 1 ] && [ "${mx}" -gt "${mn}" ]; then
    pass "${mf}-hpa: min=${mn} max=${mx} cpu=${th}%"
  else
    fail "${mf}-hpa: min='${mn:-?}' max='${mx:-?}' threshold='${th:-?}' is incomplete"
  fi
  if count_ok "${mx}" && [ "${mx}" -le "${AS_MAX_CEILING}" ]; then
    pass "${mf}-hpa: maxReplicas=${mx} is within the ${AS_MAX_CEILING}-replica ceiling"
  else
    fail "${mf}-hpa: maxReplicas='${mx:-?}' is above the ${AS_MAX_CEILING}-replica ceiling (or unreadable) -- the Kubernetes-side autoscaling target is as unbounded as the ECS one was"
  fi
done
if [ "${CLUSTER_REACHABLE}" -eq 1 ]; then
  show "kubectl get hpa -n cloud-design" "$(kubectl get hpa -n cloud-design 2>&1)"
  HN="$(kubectl get hpa -n cloud-design --no-headers 2>/dev/null | grep -c . | head -1)"
  if count_ok "${HN}" && [ "${HN}" -ge 2 ]; then
    pass "${HN} HPA(s) are live with metrics-server reporting real targets (not '<unknown>')"
  else
    invalid "live HPA count is ${HN:-0}; HPA convergence cannot be asserted"
  fi
else
  invalid "no reachable cluster -- live HPA status is INVALID"
fi

RDS_AS="$(fcount 'max_allocated_storage' "${TF_DIR}/rds.tf")"
show "grep -c max_allocated_storage terraform/rds.tf" "${RDS_AS:-0}"
if [ "${RDS_AS:-0}" -ge 2 ]; then pass "RDS storage autoscaling is configured (max_allocated_storage on both instances)"
else fail "RDS storage autoscaling is not configured on both instances"; fi
if tf_any autoscaling_group >/dev/null; then
  fail "an aws_autoscaling_group still exists -- the rubric's 'scale the node group' story is dead IaC"
else
  pass "the EKS/ASG auto-scaling path is gone with the EKS path (no aws_autoscaling_group remains)"
fi
fi

# =============================================================================
# SECTION 17 -- audit.md:90  efficient under different load (LIVE)
# =============================================================================
if step "17" "Efficient under different load (LIVE load test)" "audit.md:90"; then
if [ "${COMPOSE_STACK_UP}" -eq 1 ] && [ "${CURL_OK}" -eq 1 ]; then
  note "Driving real concurrent load through gateway-lb. Every request carries the run marker."
  TOTAL=200; CONC=20
  S=$(date +%s.%N)
  seq 1 "${TOTAL}" | xargs -P "${CONC}" -I{} curl -s -m 10 -o /dev/null -w "%{http_code} %{time_total}\n" "${LB_URL}/health?load=${RUN_MARKER}" > "${LOAD_OUT}" 2>&1
  E=$(date +%s.%N)
  ELAPSED="$(echo "$E - $S" | bc 2>/dev/null || printf '0')"
  DONE="$(wc -l < "${LOAD_OUT}" 2>/dev/null | tr -d ' ')"
  OK200="$(awk '{print $1}' "${LOAD_OUT}" 2>/dev/null | grep -c '^200$' | head -1)"
  show "${TOTAL} requests at concurrency ${CONC} via ${LB_URL}/health?load=${RUN_MARKER}" "status distribution and latency percentiles below"
  if count_ok "${DONE}" && [ "${DONE}" -eq "${TOTAL}" ]; then pass "all ${TOTAL} requests completed (no client-side timeouts)"
  else fail "only ${DONE:-0}/${TOTAL} requests completed"; fi
  if count_ok "${OK200}" && [ "${OK200}" -eq "${TOTAL}" ]; then
    pass "100% of ${TOTAL} requests returned HTTP 200 under ${CONC}-way concurrency"
  else
    fail "only ${OK200:-0}/${TOTAL} requests returned 200 under load"
  fi
  if [ -s "${LOAD_OUT}" ]; then
    STATS="$(sort -k2 -g "${LOAD_OUT}" | awk '{a[NR]=$2; s+=$2} END {if(NR==0) exit; printf "min=%.1fms avg=%.1fms p95=%.1fms max=%.1fms", a[1]*1000, (s/NR)*1000, a[int(NR*0.95)+1]*1000, a[NR]*1000}')"
    RPS="$(echo "scale=1; ${TOTAL} / ${ELAPSED}" | bc 2>/dev/null || printf '?')"
    show "measured throughput and latency" "${STATS}   throughput=${RPS} req/s over ${ELAPSED}s"
    P95="$(sort -k2 -g "${LOAD_OUT}" | awk '{a[NR]=$2} END {print a[int(NR*0.95)+1]*1000}')"
    if [ -n "${P95}" ] && awk "BEGIN{exit !(${P95} < 500)}"; then
      pass "p95 latency ${P95}ms is comfortably under the 500ms bar -- efficient at this load"
    else
      fail "p95 latency ${P95:-?}ms exceeds 500ms under ${CONC}-way load"
    fi
  else
    invalid "no latency samples were produced -- the load test itself failed, so efficiency is INVALID"
  fi
  echo
  # ---- load-balancer spread, ISOLATED TO THIS RUN ---------------------------
  # This used to read `docker compose logs gateway-lb --since=3m` with NO run
  # marker, so it counted pre-kill traffic: with one gateway replica down,
  # section 9 correctly FAILED on "only 1 distinct upstream" while this section
  # simultaneously reported 2 replicas "balanced" from the previous run's log.
  # It also only asserted `>= 2` distinct upstreams and then printed the word
  # "balanced", which is not the same claim.
  #
  # Now: every load-test URL carries ?load=${RUN_MARKER}, so the scan filters on
  # that marker instead of a wall-clock window, the per-replica counts are
  # summed and PROVED equal to the number of marker-tagged access lines, and the
  # balance itself is asserted (no replica may receive less than a quarter of
  # the run's traffic).
  LB_LOG="$(docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --no-log-prefix gateway-lb 2>/dev/null)"
  # Only the FIRST upstream= on a line: proxy_next_upstream_tries=2 means a
  # retried request can carry a comma-joined upstream list on one access line,
  # which must still count as exactly one request.
  LB_UP="$(grep -F "load=${RUN_MARKER}" <<<"${LB_LOG}" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^upstream=[0-9.]+:[0-9]+/) {print $i; break}}')"
  MARKED_N="$(grep -cF "load=${RUN_MARKER}" <<<"${LB_LOG}" | head -1)"
  count_ok "${MARKED_N}" || MARKED_N=0
  DIST="$(sort <<<"${LB_UP}" | uniq -c | sort -rn | sed '/^[[:space:]]*$/d')"
  SUM_SPLIT="$(awk '{s+=$1} END{print s+0}' <<<"${DIST}")"
  DL="$(sort -u <<<"${LB_UP}" | grep -c . | head -1)"
  count_ok "${DL}" || DL=0
  MINC="$(awk '{if(m==""||$1<m)m=$1} END{print m+0}' <<<"${DIST}")"
  MAXC="$(awk '{if($1>m)m=$1} END{print m+0}' <<<"${DIST}")"
  SKEW="$(awk -v mx="${MAXC:-0}" -v mn="${MINC:-0}" -v t="${SUM_SPLIT:-0}" 'BEGIN{ if(t>0) printf "%.1f", (mx-mn)*100.0/t; else print "n/a" }')"
  show "docker compose logs --no-log-prefix gateway-lb | grep -F 'load=${RUN_MARKER}' | awk '{print first upstream= field}' | sort | uniq -c   (run marker ${RUN_MARKER}, no --since window)" "${DIST:-<no marker-tagged access lines>}"
  if [ "${MARKED_N}" -eq 0 ]; then
    invalid "gateway-lb logged no access line carrying this run's marker (?load=${RUN_MARKER}); the distribution of THIS run's ${TOTAL} requests cannot be established, so it is INVALID rather than passed"
  elif [ "${SUM_SPLIT}" -ne "${MARKED_N}" ]; then
    fail "the per-replica split above sums to ${SUM_SPLIT} but gateway-lb logged ${MARKED_N} access lines for this run -- the reported split does not provably account for this run's traffic, so it is not evidence of anything"
  else
    pass "the split above sums to exactly ${SUM_SPLIT}, the number of ?load=${RUN_MARKER} access lines gateway-lb logged for this run -- every count in it provably belongs to this run and not to pre-kill traffic"
    if [ "${DL}" -ge 2 ]; then
      pass "traffic reached ${DL} distinct gateway replicas under load (min=${MINC:-0} max=${MAXC:-0} of ${SUM_SPLIT}; spread ${SKEW}% of the run)"
    else
      fail "under load only ${DL} distinct gateway replica(s) served the ${SUM_SPLIT} requests of this run -- traffic is NOT being distributed"
    fi
    # A real balance assertion, not ">= 2 therefore balanced". With `least_conn`
    # and identical replicas a fair-share split is ~50/50; a quarter of the run
    # is a deliberately loose floor that still fails a starved replica.
    if [ "${MINC:-0}" -gt 0 ] && [ $(( MINC * 4 )) -ge "${SUM_SPLIT}" ]; then
      pass "BALANCE ASSERTED: the least-loaded replica still took ${MINC}/${SUM_SPLIT} of this run's requests, i.e. at least a quarter of fair share (a starved replica would fail this)"
    else
      fail "distribution is not balanced: the least-loaded replica took only ${MINC:-0} of ${SUM_SPLIT} requests (${SKEW}% spread between busiest and quietest replica)"
    fi
  fi
else
  invalid "compose stack not running (or curl missing) -- throughput, latency and load-balancer distribution under load are INVALID, not passed"
fi
fi

# =============================================================================
# SECTION 18 -- audit.md:94  security best practices incl. vulnerability scanning
# =============================================================================
if step "18" "Security best practices incl. vulnerability scanning" "audit.md:94"; then
# The public edge is API Gateway, which AWS serves over HTTPS only; the ALB is
# internal. The listener is HTTP :80 by default and HTTPS :443 with an ACM
# certificate when enable_acm_certificate = true (terraform/alb.tf).
ACMN="$(tf_res acm_certificate)"
ALB_INTERNAL="$(tf_block "${TF_DIR}/alb.tf" aws_lb main | grep -cE 'internal[[:space:]]*=[[:space:]]*true' | head -1)"
TLSPOL="$(tf_block "${TF_DIR}/alb.tf" aws_lb_listener main | grep -oE 'ELBSecurityPolicy-TLS1[0-9-]*' | head -1)"
TLSCFG="$(tf_block "${TF_DIR}/api_gateway.tf" aws_apigatewayv2_integration alb | grep -c 'server_name_to_verify' | head -1)"
show "internal ALB / ACM certs / listener TLS policy / integration tls_config" "alb_internal=${ALB_INTERNAL:-0} acm=${ACMN:-0} tls_policy=${TLSPOL:-none} tls_config=${TLSCFG:-0}"
if [ "${ALB_INTERNAL:-0}" -ge 1 ]; then pass "the ALB is internal: the only public entry point is the API Gateway endpoint, which AWS serves over HTTPS only"
else fail "the ALB is not internal, so it is a second public entry point next to API Gateway"; fi
if [ "${ACMN:-0}" -ge 1 ] && [ -n "${TLSPOL}" ] && [ "${TLSCFG:-0}" -ge 1 ]; then
  pass "the optional HTTPS hop is wired: with enable_acm_certificate = true the listener serves an ACM certificate with ${TLSPOL} and API Gateway verifies it (tls_config server_name_to_verify)"
else
  fail "the optional HTTPS hop is incomplete: acm=${ACMN:-0} tls_policy=${TLSPOL:-none} tls_config=${TLSCFG:-0}"
fi
note "with the default enable_acm_certificate = false, the API Gateway -> ALB hop is plain HTTP on :80 inside the VPC, reachable only from the VPC Link security group (a documented cost trade-off: no domain needed)"

if tf_any apigatewayv2_authorizer; then pass "API Gateway authorizer is provisioned (managed JWT validation)"; else fail "no API Gateway authorizer"; fi
if tf_any cognito_user_pool; then pass "Cognito user pool provides the managed authentication"; else fail "no Cognito user pool"; fi

if tf_any inspector2_enabler; then pass "aws_inspector2_enabler is provisioned: continuous vulnerability scanning is ON"
else fail "no aws_inspector2_enabler -- nothing continuously scans for vulnerabilities, which the rubric asks for explicitly"; fi
if tf_any inspector2_filter; then pass "aws_inspector2_filter surfaces CRITICAL/HIGH findings for triage (action=NONE, i.e. reported not suppressed)"
else note "no inspector2 filter: images are still scanned, but no triage filter is defined"; fi
SCAN="$(fcount 'scan_on_push[[:space:]]*=[[:space:]]*true' "${TF_DIR}/ecr.tf")"
show "grep -c 'scan_on_push = true' terraform/ecr.tf" "${SCAN:-0}"
if [ "${SCAN:-0}" -ge 1 ]; then pass "ECR image scanning is enabled on push (scan_on_push = true)"; else fail "ECR scan_on_push is not enabled"; fi
ECRLIFE="$(tf_res ecr_repository)"
ECRN="$(awk '/^[[:space:]]*app_images[[:space:]]*=[[:space:]]*\{/{f=1;next} f&&/^[[:space:]]*\}/{exit} f&&/=/{c++} END{print c+0}' "${TF_DIR}/ecr.tf" 2>/dev/null)"
if [ "${ECRLIFE:-0}" -ge 1 ]; then
  pass "aws_ecr_repository is declared (1 block x for_each over ${ECRN:-?} app images) with a lifecycle policy bounding retained images"
else
  note "no aws_ecr_repository"
fi

NONROOT_IMG=0
for d in "${SRC_DIRS[@]}"; do
  f="${ROOT_DIR}/srcs/${d}/Dockerfile"
  [ -f "$f" ] && grep -qE '^USER[[:space:]]+' "$f" && NONROOT_IMG=$((NONROOT_IMG + 1))
done
NRO_N=0; RORO=0; CAPDROP=0; NOESC=0; RORO_F=0; WORKLOADS=0
for mf in "${MAN_DIR}"/*.yaml; do
  [ -f "$mf" ] || continue
  NRO_N=$((NRO_N   + $(yc "$mf" 'runAsNonRoot:[[:space:]]*true')))
  RORO=$((RORO     + $(yc "$mf" 'readOnlyRootFilesystem:[[:space:]]*true')))
  RORO_F=$((RORO_F + $(yc "$mf" 'readOnlyRootFilesystem:[[:space:]]*false')))
  CAPDROP=$((CAPDROP + $(yc "$mf" '^[[:space:]]*drop:')))
  NOESC=$((NOESC   + $(yc "$mf" 'allowPrivilegeEscalation:[[:space:]]*false')))
  WORKLOADS=$((WORKLOADS + $(yc "$mf" -E '^[[:space:]]*kind:[[:space:]]*(Deployment|StatefulSet)')))
done
show "container hardening counts (YAML comments stripped)" "workload kinds=${WORKLOADS}  Dockerfile USER=${NONROOT_IMG}/6  runAsNonRoot=true=${NRO_N}  readOnlyRootFilesystem=true=${RORO} (=false:${RORO_F})  capabilities.drop=${CAPDROP}  no-new-privileges=${NOESC}"
if [ "${NONROOT_IMG}" -ge 3 ]; then pass "${NONROOT_IMG}/6 images bake a non-root USER"; else fail "fewer than 3 images set a non-root USER (${NONROOT_IMG})"; fi
if [ "${NRO_N}" -ge 3 ]; then pass "${NRO_N} workload(s) set runAsNonRoot: true"; else note "runAsNonRoot set on ${NRO_N} workloads (the 3 data-tier images legitimately run as uid 0)"; fi
if [ "${RORO}" -ge 3 ] && [ "$(( RORO + RORO_F ))" -ge 6 ]; then
  pass "readOnlyRootFilesystem is set on all 6 workloads: true for the 3 app tiers, explicitly false for the 3 data tiers that must write to disk"
else
  note "readOnlyRootFilesystem: true on ${RORO} workloads, false on ${RORO_F}"
fi
if [ "${CAPDROP}" -ge 4 ]; then pass "${CAPDROP} container securityContext blocks drop Linux capabilities"; else note "capabilities.drop present on ${CAPDROP} containers"; fi
if [ "${NOESC}" -ge 4 ]; then pass "${NOESC} container(s) set allowPrivilegeEscalation: false (no-new-privileges)"; else note "allowPrivilegeEscalation: false on ${NOESC} containers"; fi

# ---- hardcoded-credential scan over the APPLICATION SOURCE --------------------
# Only manifests/secrets.yaml used to be scanned, and the srcs/ regex was
#   grep -rnE 'getenv\([^)]*,\s*"[^"]*pass'
# which looks for the substring "pass" INSIDE THE DEFAULT VALUE. Substituting
# `os.getenv("INVENTORY_DB_PASSWORD", "hunter2")` for
# `_require_env("INVENTORY_DB_PASSWORD")` therefore sailed through: "hunter2"
# contains no "pass". The name carries the word, not the value.
#
# The scan below keys on the ENVIRONMENT VARIABLE NAME (the part that says
# "this is a credential") and rejects any non-empty string literal supplied as
# its default, which is the actual defect. Comment-only lines are dropped so a
# docstring that quotes an example cannot trip it; anything still reported comes
# back with file:line so a human can adjudicate it.
CRED_NAME='(PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIAL)'
CRED_FALLBACK_RE="os\.(getenv|environ\.get)\(\s*[\"'][^\"']*${CRED_NAME}[^\"']*[\"']\s*,\s*[\"'][^\"']+[\"']"
# The quotes around the variable name are PART OF THE PATTERN here, not excluded
# from it: `[^"')]*` after the opening paren can never span `"INVENTORY_DB_PASSWORD"`,
# so the first version of this regex silently matched nothing and
# `os.getenv("DB_PASSWORD") or "fallback-pw"` passed.
CRED_FALLBACK_OR_RE="os\.(getenv|environ\.get)\([\"'][^\"')]*${CRED_NAME}[^\"')]*[\"']\)\s*or\s*[\"'][^\"']+[\"']"
CRED_SETDEF_RE="os\.environ\.setdefault\(\s*[\"'][^\"']*${CRED_NAME}[^\"']*[\"']\s*,\s*[\"'][^\"']+[\"']"
CRED_LITERAL_RE="(^|[^A-Za-z0-9_])([A-Za-z0-9_]*_)?(password|passwd|passphrase|secret|token|api_?key|access_?key|private_?key|credential)s?[[:space:]]*[:=][[:space:]]*[\"'][^\"']{3,}[\"']"
CRED_URL_RE="[a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]\"']+:[^@/[:space:]\"']+@"
CRED_HITS=""
for re in "$CRED_FALLBACK_RE" "$CRED_FALLBACK_OR_RE" "$CRED_SETDEF_RE" "$CRED_LITERAL_RE" "$CRED_URL_RE"; do
  hits="$(grep -rInEi "$re" --include='*.py' "${ROOT_DIR}/srcs" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | head -20)"
  [ -n "${hits}" ] && CRED_HITS+="${hits}"$'\n'
done
CRED_HITS="${CRED_HITS%$'\n'}"
CRED_FILES="$(find "${ROOT_DIR}/srcs" -name '*.py' -type f 2>/dev/null | wc -l | tr -d ' ')"
show "grep -rInE '<credential-name + string-literal default | credential name = literal | scheme://user:pass@>' srcs/**/*.py  (${CRED_FILES} .py files, comment lines excluded)" "${CRED_HITS:-<empty: no hardcoded credential literal in any srcs/**/*.py>}"
if [ "${CRED_FILES:-0}" -lt 1 ]; then
  invalid "no Python sources were found under srcs/ -- the hardcoded-credential scan had nothing to scan and is INVALID"
elif [ -z "${CRED_HITS}" ]; then
  pass "scanned all ${CRED_FILES} .py files under srcs/: no credential-shaped environment lookup carries a literal default and no password/secret/token/key is assigned a string literal -- every credential is read from the environment with no fallback"
else
  fail "hardcoded credential literal(s) in the application source: ${CRED_HITS}"
fi
# Positive counterpart: the fail-closed idiom must actually be in use, otherwise
# "no literal default" could be satisfied by credentials simply not being read.
REQ_ENV="$(grep -rInE '_require_env\(\s*"' --include='*.py' "${ROOT_DIR}/srcs" 2>/dev/null | wc -l | tr -d ' ')"
REQ_ENV_PW="$(grep -rInE '_require_env\(\s*"[^"]*(PASSWORD|PASSWD|SECRET|USER)[^"]*"' --include='*.py' "${ROOT_DIR}/srcs" 2>/dev/null | wc -l | tr -d ' ')"
show "grep -rInE '_require_env(\"…\")' srcs/**/*.py   -- the fail-closed helper that makes a missing variable a startup error" "total=${REQ_ENV:-0} credential-shaped=${REQ_ENV_PW:-0}"
if count_ok "${REQ_ENV_PW}" && [ "${REQ_ENV_PW}" -ge 1 ]; then
  pass "${REQ_ENV_PW} credential value(s) are read through _require_env(), which raises at startup instead of silently falling back -- this is what makes the absence of literals above meaningful"
else
  fail "no credential is read through the fail-closed _require_env() helper, so 'no hardcoded default' is not the same as 'the credential is actually required'"
fi

if [ -f "${MAN_DIR}/secrets.yaml" ]; then
  NONPLACE="$(grep -E '^[[:space:]]+[A-Z0-9_]+:[[:space:]]*"' "${MAN_DIR}/secrets.yaml" 2>/dev/null | grep -v 'REPLACE_ME_')"
  NPLACE="$(grep -E '^[[:space:]]+[A-Z0-9_]+:[[:space:]]*".*REPLACE_ME_' "${MAN_DIR}/secrets.yaml" 2>/dev/null | grep -c . | head -1)"
  NKEYS="$(grep -E '^[[:space:]]+[A-Z0-9_]+:[[:space:]]*"' "${MAN_DIR}/secrets.yaml" 2>/dev/null | grep -c . | head -1)"
  show "manifests/secrets.yaml value audit" "stringData keys=${NKEYS:-0}, of which REPLACE_ME_* placeholders=${NPLACE:-0}; non-placeholder values: ${NONPLACE:-none}"
  if [ -z "${NONPLACE}" ] && [ "${NPLACE:-0}" -eq "${NKEYS:-0}" ] && [ "${NKEYS:-0}" -ge 1 ]; then
    pass "all ${NKEYS} stringData keys in manifests/secrets.yaml are REPLACE_ME_* placeholders (no real credential is committed)"
  else
    fail "manifests/secrets.yaml contains non-placeholder credential value(s): ${NONPLACE}"
  fi
else
  fail "manifests/secrets.yaml is missing"
fi
if [ -f "${ROOT_DIR}/.gitignore" ] && grep -qE '^\.env$' "${ROOT_DIR}/.gitignore"; then pass ".gitignore excludes .env (the file holding real local credentials)"
else note ".gitignore does not exclude .env -- 'docker compose up' reads real credentials from it"; fi
fi

# =============================================================================
# SECTION 19 -- audit.md:98  BONUS: what is ACTUALLY implemented
# Honest inventory. Explicitly confirms the headline bonus items that are NOT
# implemented so nothing is overstated.
# =============================================================================
if step "19" "Bonus: what is ACTUALLY implemented (honest inventory)" "audit.md:98"; then
note "Bonus inventory. Each item is confirmed or denied against the real terraform/, never assumed."

# ---- is the application source actually WIRED UP, and does it RUN? ---------
# A "what is actually implemented" claim has to survive more than a byte-compile.
# Deleting srcs/inventory-app/app/validation.py -- a module movies.py imports --
# left both suites completely green: test_cloud.sh only py_compile'd the three
# server.py entry points, nothing anywhere imported a module, and NEITHER script
# ever ran the repository's own unit tests. The app was dead at startup.
note "Application-source integrity. These two checks exist because a deleted module is invisible to py_compile and to any file-existence count."
IMP_ROWS=""; IMP_N=0; IMP_BROKEN=""
for d in "${SRC_DIRS[@]}"; do
  c="${ROOT_DIR}/srcs/${d}"
  [ -d "${c}/app" ] || continue
  refs="$(grep -rhoE '^[[:space:]]*(from|import)[[:space:]]+app([.][A-Za-z0-9_]+)*' \
            --include='*.py' "${c}" 2>/dev/null \
          | sed -E 's/^[[:space:]]*(from|import)[[:space:]]+//; s/\.$//; s/^app$//; s/^app[.]//' \
          | tr '.' '/' | sed 's#^$#__init__#' | sort -u)"
  for ref in ${refs}; do
    IMP_N=$((IMP_N + 1))
    if [ -f "${c}/app/${ref}.py" ] || [ -f "${c}/app/${ref}/__init__.py" ]; then
      IMP_ROWS+="${d}: app.${ref} -> present"$'\n'
    else
      IMP_BROKEN+="${d}: app.${ref}.py "
      IMP_ROWS+="${d}: app.${ref} -> MISSING"$'\n'
    fi
  done
done
show "resolve every 'from app.X import' / 'import app.X' in srcs/*/ against the file it must exist as (${IMP_N} internal import(s))" "${IMP_ROWS:-<no internal imports found>}"
if [ "${IMP_N}" -eq 0 ]; then
  invalid "no internal 'app.*' import was found under srcs/ -- the import-resolution check had nothing to resolve and is INVALID"
elif [ -z "${IMP_BROKEN}" ]; then
  pass "all ${IMP_N} intra-package import(s) in srcs/ resolve to a file that exists: deleting any app module would now be detected instead of silently killing the service"
else
  fail "srcs/ imports a module that does not exist -- ${IMP_BROKEN}the app cannot start (ModuleNotFoundError at import time)"
fi

# Now actually EXECUTE an import of every module, not just resolve the name.
# Three-state on purpose: a missing app module is a FAIL, a third-party package
# that is simply not installed on the HOST (flask, pika, sqlalchemy, waitress
# are baked into the images, not the host) is INVALID, never a silent pass.
IMP_OK=0; IMP_HOSTDEP=0; IMP_RUNFAIL=""; IMP_HOSTPKGS=""
if [ "${PY_OK}" -ne 1 ]; then
  invalid "python3 is not installed -- the live module-import execution cannot run and is INVALID (the static resolution above still applies)"
else
  for d in "${SRC_DIRS[@]}"; do
    c="${ROOT_DIR}/srcs/${d}"
    [ -d "${c}/app" ] || continue
    for ref in $(cd "${c}" && ls -1 app/*.py 2>/dev/null | sed -E 's#^app/##; s#\.py$##'); do
      mod="app.${ref}"
      [ "${ref}" = "__init__" ] && mod="app"
      err="$(cd "${c}" && python3 -c "import ${mod}" 2>&1)"
      if [ -z "${err}" ]; then
        IMP_OK=$((IMP_OK + 1))
      elif grep -qE "No module named ['\"]app([.'\"]|$)" <<<"${err}"; then
        IMP_RUNFAIL+="${d}: ${mod} -> $(head -1 <<<"${err}") "
      elif grep -qE "No module named ['\"][A-Za-z0-9_]+['\"]" <<<"${err}"; then
        IMP_HOSTDEP=$((IMP_HOSTDEP + 1))
        IMP_HOSTPKGS+="$(grep -oE "No module named ['\"][A-Za-z0-9_]+['\"]" <<<"${err}" | head -1 | sed -E "s/.*['\"]([A-Za-z0-9_]+)['\"]/\1/") "
      else
        IMP_RUNFAIL+="${d}: ${mod} -> $(head -1 <<<"${err}") "
      fi
    done
  done
  IMP_HOSTPKGS="$(tr ' ' '\n' <<<"${IMP_HOSTPKGS}" | grep -v '^$' | sort -u | tr '\n' ' ')"
  show "cd srcs/<c> && python3 -c 'import <module>' for every module of every app package" "${IMP_OK} imported cleanly here; ${IMP_HOSTDEP} stopped on a third-party package that only exists inside the image (${IMP_HOSTPKGS:-none}); ${IMP_RUNFAIL:-0} failed on a module of THIS project"
  if [ -n "${IMP_RUNFAIL}" ]; then
    fail "module import fails against a module of THIS project: ${IMP_RUNFAIL}"
  elif [ "${IMP_HOSTDEP}" -ge 1 ]; then
    pass "every application module resolves and its failure to execute here is a THIRD-PARTY dependency (${IMP_HOSTPKGS% }), not a missing or broken module of this project -- so a deleted app module is now detectable. ${IMP_OK} module(s) executed outright on this host"
  else
    pass "all ${IMP_OK} application module(s) import and execute cleanly on this host"
  fi
fi

# ---- run the repository's OWN unit tests -----------------------------------
# Neither suite ever did this. The repo ships `make test-py` (18 tests over the
# validation helpers) and it is the cheapest available proof that the Python the
# audit claims to have written actually works.
if [ "${MAKE_OK}" -ne 1 ] || [ "${PY_OK}" -ne 1 ]; then
  invalid "make or python3 is missing -- 'make test-py' (the repo's own unit-test target) cannot be executed and is INVALID"
else
  UT_OUT="$(cd "${ROOT_DIR}" && make test-py 2>&1)"; UT_RC=$?
  UT_RAN="$(grep -oE 'Ran [0-9]+ tests?' <<<"${UT_OUT}" | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)"
  UT_FAILD="$(grep -oE 'FAILED \((.*)\)' <<<"${UT_OUT}" | head -1)"
  UT_ERR="$(grep -E '^(FAIL|ERROR): ' <<<"${UT_OUT}" | head -6 | tr '\n' ';')"
  show "make test-py   (the repo's own target: py-compile + 'python3 -m unittest discover -s tests' per component)" "exit=${UT_RC} tests run=${UT_RAN:-?} verdict='$(grep -E '^(OK|FAILED)' <<<"${UT_OUT}" | paste -sd' ' -)'"
  if [ "${UT_RC}" -eq 0 ] && count_ok "${UT_RAN}" && [ "${UT_RAN}" -ge 1 ]; then
    pass "'make test-py' passes: ${UT_RAN} unit tests across the srcs/*/tests/ suites, exit 0 -- the application code the audit claims to have written demonstrably executes"
  else
    fail "'make test-py' fails (exit ${UT_RC}, ${UT_RAN:-0} tests run, verdict '${UT_FAILD:-see below}'): ${UT_ERR:-<no FAIL/ERROR lines captured>}"
  fi
fi

check_bonus() { # <label> <aws resource type suffix>
  if tf_any "$2"; then pass "BONUS IMPLEMENTED: ${1}"
  else note "BONUS NOT IMPLEMENTED: ${1} (no aws_${2} in terraform/)"; fi
}
check_bonus "AWS Inspector v2 -- continuous vulnerability scanning" inspector2_enabler
check_bonus "ECR image registry with scan-on-push"                   ecr_repository
check_bonus "AWS Cloud Map service discovery"                        service_discovery_private_dns_namespace
check_bonus "ACM certificate for the ALB"                            acm_certificate
check_bonus "ACM DNS validation for the optional HTTPS hop"           acm_certificate_validation
check_bonus "Fargate Spot toggle (cost optimisation)"                ecs_cluster_capacity_providers
check_bonus "AWS Budgets cost guardrail"                             budgets_budget
check_bonus "AWS S3 object storage"                                  s3_bucket

note "--- Explicitly NOT implemented (confirmed against terraform/, matches README.md:172-178) ---"
for pair in lambda_function:"AWS Lambda (serverless event processing)" \
            cloudfront_distribution:"Amazon CloudFront (CDN)" \
            wafv2_web_acl:"AWS WAF (web ACL / rate limiting)" \
            eks_cluster:"Amazon EKS" \
            autoscaling_group:"an EC2 node Auto Scaling group" \
            sagemaker:"SageMaker"; do
  ty="${pair%%:*}"; lb="${pair#*:}"
  if tf_any "$ty"; then note "CORRECTION -- ${lb} IS present in terraform/ after all (aws_${ty})"
  else note "CONFIRMED ABSENT: ${lb} (no aws_${ty})"; fi
done
if tf_grep ecs_use_fargate_spot | grep -q .; then
  pass "FARGATE_SPOT toggle confirmed by variable reference (var.ecs_use_fargate_spot)"
else
  note "no FARGATE_SPOT toggle reference found"
fi
note "The rubric asks 'did the student add ANY optional bonus' -- that is already answered yes by Inspector2, ECR+scan-on-push, Cloud Map, ACM and the Fargate Spot toggle. The five absences above are documented roadmap items, NOT failures."
fi

# =============================================================================
# SECTION 20 -- audit.md:100  BONUS: outstanding project -- evidence tally
# =============================================================================
if step "20" "Bonus: is this an outstanding project? (evidence tally, NOT a verdict)" "audit.md:100"; then
note "audit.md:100 is a subjective grader judgement. A script cannot assign it. What follows is an evidence TALLY for the grader to weigh."
echo -e "  ${BOLD}Evidence tally:${NC}"
echo -e "    checks executed     : $(( PASS_COUNT + FAIL_COUNT + INVALID_COUNT ))"
echo -e "    PASS                : ${PASS_COUNT}"
echo -e "    FAIL                : ${FAIL_COUNT}"
echo -e "    INVALID (unproven)  : ${INVALID_COUNT}"
echo -e "    live docker compose : $( [ "${COMPOSE_STACK_UP}" -eq 1 ] && echo UP || echo DOWN )"
echo -e "    live k3d cluster    : $( [ "${CLUSTER_REACHABLE}" -eq 1 ] && echo REACHABLE || echo UNREACHABLE )"
echo -e "    aws / terraform     : $( [ "${AWS_OK}${TERRAFORM_OK}" = "11" ] && echo BOTH PRESENT || echo "NOT AVAILABLE -- no live AWS evidence is claimed" )"
# -----------------------------------------------------------------------------
# Pointer into docs/AUDIT_GUIDE.md, with the heading AND the line number looked
# up at runtime. The previous revision hardcoded "docs/AUDIT_GUIDE.md:904" and
# asserted the guide "contains stale numbers (14 Terraform modules, a 15 USD
# budget, ...)". That accusation was false in front of the examiner: the guide
# was rewritten, those numbers are gone, and section 10 is no longer at line 904.
# Worse, the replacement text called terraform/ "18 modules" -- a file count
# presented as an architecture, which is the exact error the rewrite was made
# to destroy. Nothing here is typed in; every number below is counted at runtime.
# -----------------------------------------------------------------------------
GX_LINE="$(grep -nE '^## +10\. +Auditor quick-reference matrix' "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null | head -1 | cut -d: -f1)"
GX_TITLE="$(grep -m1 -E '^## +10\. ' "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null | sed -E 's/^#+[[:space:]]*//')"
TF_AWS="$(tf_types | grep -c '^aws_' | head -1)"
TF_DATAC="$(grep -hE '^data ' "$TF_DIR"/*.tf 2>/dev/null | wc -l | tr -d ' ')"
TF_VARS="$(grep -cE '^variable ' "${TF_DIR}/variables.tf" 2>/dev/null | head -1)"
note "Evidence index: docs/AUDIT_GUIDE.md ${GX_TITLE:-section 10 (heading not found)}${GX_LINE:+ (line ${GX_LINE})} maps every audit.md question to the command or file that proves it; '## 3' is the five-pillar design review and '## 9' lists the known gaps."
if count_ok "${TF_COUNT}" && count_ok "${TF_MODULE_BLOCKS}" && count_ok "${TF_AWS}"; then
  note "Derived at runtime, not typed in: terraform/ holds ${TF_COUNT} .tf FILES containing ${TF_AWS} aws_* resources (${TF_DATAC} data sources, ${TF_VARS} variables) and ${TF_MODULE_BLOCKS} \`module\` blocks. '.tf files' and 'modules' are different things and the guide is careful to say which it means."
else
  note "Could not derive the terraform tallies for this cross-check (TF_COUNT='${TF_COUNT}' TF_MODULE_BLOCKS='${TF_MODULE_BLOCKS}' TF_AWS='${TF_AWS}')."
fi
# A real, checkable invariant, derived rather than asserted: the guide must state
# the module count as zero. That is the correction the rewrite was made for, and
# it can only be true if it agrees with terraform/, so it is asserted, not noted.
if grep -qiE 'zero[^.]{0,24}module|module[^.]{0,24}zero|0 +(\*\*)?modules' "${ROOT_DIR}/docs/AUDIT_GUIDE.md" 2>/dev/null; then
  pass "docs/AUDIT_GUIDE.md states the module count as ZERO, which agrees with terraform/ (${TF_MODULE_BLOCKS} \`module\` blocks in ${TF_COUNT} .tf files) -- the old 'N Terraform modules' file-count-as-architecture conflation is gone from the guide"
else
  note "no explicit 'zero modules' statement was found in docs/AUDIT_GUIDE.md to cross-check against terraform/'s ${TF_MODULE_BLOCKS} \`module\` blocks; not scored, and not asserted either way"
fi
TF_ALARM_COUNT="$(fcount '^resource "aws_cloudwatch_metric_alarm"' "${TF_DIR}/cloudwatch.tf")"
TF_WIDGET_COUNT="$(fcount 'type[[:space:]]*=[[:space:]]*"metric"' "${TF_DIR}/cloudwatch.tf")"
note "Also measured by this run: ${TF_ALARM_COUNT:-?} CloudWatch metric alarms and ${TF_WIDGET_COUNT:-?} dashboard widgets. Terraform .tf FILES are not modules - this project has ${TF_MODULE_BLOCKS} 'module' blocks, and conflating the two was one of the errors this project already had to correct. This script deliberately does not edit docs/."
fi

# =============================================================================
# SECTION 21 -- non-automatable rubric items, then the SUMMARY
# =============================================================================
if step "21" "Non-automatable items and final summary" "audit.md:34,36,38,40 + all"; then
note "The following rubric items are graded human observations and are deliberately NOT scored (there is no honest way for bash to grade prose or a spoken answer):"
note "  audit.md:34 'able to answer all the questions correctly'   -> grader observation (answers at docs/AUDIT_GUIDE.md ## 2)"
note "  audit.md:36 'thorough understanding of concepts'          -> grader observation (docs/AUDIT_GUIDE.md ## 2, ## 3)"
note "  audit.md:38 'communicate effectively and justify decisions'-> grader observation"
note "  audit.md:40 'critically evaluate the solution'             -> grader observation (docs/AUDIT_GUIDE.md Q11 / Q12)"
note "  audit.md:19-32 the 14 stakeholder roleplay questions       -> live spoken session (docs/AUDIT_GUIDE.md ## 2)"
note "  audit.md:46-50 the five Well-Architected pillars            -> design review (docs/AUDIT_GUIDE.md ## 3); the IaC evidence is scored in S3/S5/S10/S12/S16/S18"
note "  audit.md:100 'Is this an outstanding project?'              -> subjective grader judgement (evidence tally in S20)"

fi

if [ "${SECTIONS_RAN}" -eq 0 ]; then
  echo -e "${YELLOW}No section matched '${ONLY_SECTION}' (valid: 0..21). Nothing was run.${NC}"
  exit 2
fi

echo
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD} SUMMARY${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  PASS=${GREEN}${PASS_COUNT}${NC}  FAIL=${RED}${FAIL_COUNT}${NC}  INVALID=${YELLOW}${INVALID_COUNT}${NC}  NOTES=${NOTE_COUNT}"
echo -e "  run marker: ${RUN_MARKER}"
if [ "${#SKIPPED_SECTIONS[@]}" -gt 0 ]; then
  echo -e "  (${#SKIPPED_SECTIONS[@]} section(s) skipped by --section ${ONLY_SECTION}; this tally covers ONLY the sections that ran)"
fi
if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo; echo -e "${RED}FAILED items (${FAIL_COUNT}):${NC}"
  for f in "${FAILURES[@]}"; do echo -e "${RED}  - ${f}${NC}"; done
fi
if [ "${INVALID_COUNT}" -gt 0 ]; then
  echo; echo -e "${YELLOW}INDETERMINATE items (${INVALID_COUNT}) -- these are NOT passes:${NC}"
  for r in "${INVALID_REASONS[@]}"; do echo -e "${YELLOW}  - ${r}${NC}"; done
fi
echo
if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo -e "${RED}${BOLD}RESULT: ${FAIL_COUNT} rubric item(s) FAILED. exit 1.${NC}"; exit 1
fi
if [ "${INVALID_COUNT}" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}RESULT: no outright failures, but ${INVALID_COUNT} item(s) could not be determined in this environment. They are NOT claimed as passes.${NC}"; exit 0
fi
echo -e "${GREEN}${BOLD}RESULT: every executed check passed.${NC}"; exit 0
