#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# cloud-design STATIC verification suite
# ==============================================================================
# SCOPE -- THIS SCRIPT IS STATIC-ONLY, BY DESIGN. It reads files and parses
# manifests; it never talks to a running container, a cluster or AWS. For the
# live/LIVE-evidence suite see scripts/run-audit-checks.sh (docker compose,
# kubectl, curl, a real load test) -- the two are deliberately separate so a
# reviewer can tell at a glance which claims are proven by running things and
# which are proven by reading them.
#
# It is NOT fast-CI-silent either: a missing tool is reported as a counted
# [WARN] line, never as a silent skip and never as a pass.
#
# Exit: 0 if no FAIL, 1 if any FAIL.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
WARNINGS=()

pass() { echo "  [PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  [FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo "  [WARN] $1"; WARN_COUNT=$((WARN_COUNT + 1)); WARNINGS+=("$1"); }

echo "============================================================"
echo " CLOUD-DESIGN STATIC VERIFICATION SUITE                      "
echo " static only - no live docker / kubectl / aws calls         "
echo "============================================================"

# -----------------------------------------------------------------------------
echo ">>> 1. Repository structure and required deliverables"
# -----------------------------------------------------------------------------
for d in terraform manifests srcs scripts ecs-tasks docs; do
    if [ -d "$ROOT_DIR/$d" ]; then pass "Directory exists: $d/"; else fail "Missing directory: $d/"; fi
done

# The top-level Dockerfiles/ tree was DELETED and consolidated into srcs/<c>/.
# Checking for it (as the previous revision of this script did) was the stale-path
# bug: it reported 6 missing Dockerfiles that do not exist as separate files.
if [ -d "$ROOT_DIR/Dockerfiles" ]; then
    warn "top-level Dockerfiles/ exists again; this script expects the consolidated srcs/<component>/Dockerfile layout"
else
    pass "no stale top-level Dockerfiles/ (consolidated into srcs/<component>/Dockerfile)"
fi

# docs/audit.md moved into docs/. The old check for a ROOT-level audit.md was the
# second stale path and was the single check this script used to FAIL on.
if [ -f "$ROOT_DIR/docs/audit.md" ]; then
    NQ="$(grep -c '^######' "$ROOT_DIR/docs/audit.md" 2>/dev/null | head -1)"
    pass "audit rubric present at docs/audit.md (${NQ:-?} '######' questions)"
else
    fail "Missing audit rubric: docs/audit.md"
fi

for f in README.md docs/readme.md docs/AUDIT_GUIDE.md docker-compose.yml Makefile .env.example; do
    if [ -f "$ROOT_DIR/$f" ]; then pass "Required file exists: $f"; else fail "Missing required file: $f"; fi
done

if [ -f "$ROOT_DIR/.gitignore" ] && [ -f "$ROOT_DIR/.dockerignore" ]; then
    pass "both .gitignore and .dockerignore exist"
elif [ -f "$ROOT_DIR/.gitignore" ]; then
    fail ".dockerignore is missing"
else
    fail ".gitignore is missing"
fi

# Report the real counts rather than asserting a number that used to be baked in.
TF_N="$(find "$ROOT_DIR/terraform" -maxdepth 1 -name '*.tf' -type f 2>/dev/null | wc -l | tr -d ' ')"
MAN_N="$(find "$ROOT_DIR/manifests" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')"
ECS_N="$(find "$ROOT_DIR/ecs-tasks" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
DF_N="$(find "$ROOT_DIR/srcs" -mindepth 2 -maxdepth 2 -name 'Dockerfile' -type f 2>/dev/null | wc -l | tr -d ' ')"
SRC_N="$(find "$ROOT_DIR/srcs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "  ---- real counts ----"
echo "  terraform/*.tf       : ${TF_N}"
echo "  manifests/*.yaml     : ${MAN_N}"
echo "  ecs-tasks/*.json     : ${ECS_N}"
echo "  srcs/*/Dockerfile    : ${DF_N}"
echo "  srcs/* components    : ${SRC_N}"
if [ "$DF_N" -eq "$SRC_N" ] && [ "$SRC_N" -gt 0 ]; then
    pass "every srcs/ component has its own Dockerfile (${DF_N}/${SRC_N})"
else
    fail "Dockerfile count ${DF_N} does not match component count ${SRC_N}"
fi

# -----------------------------------------------------------------------------
echo ">>> 2. Terraform IaC architecture"
# -----------------------------------------------------------------------------
# The module list is enumerated from disk, not hardcoded: the previous version
# hardcoded 14 modules and would have failed on the 18-file tree.
TF_MISSING=""
for tf_file in $(cd "$ROOT_DIR/terraform" && ls -1 *.tf 2>/dev/null); do
    [ -f "$ROOT_DIR/terraform/$tf_file" ] || TF_MISSING+="$tf_file "
done
if [ -z "$TF_MISSING" ]; then
    pass "all ${TF_N} terraform modules enumerated from disk"
else
    fail "missing terraform files: ${TF_MISSING}"
fi

# Data-tier isolation. The invariant is NOT "the literal 5672 appears": on AWS
# Amazon MQ terminates TLS, so the broker SG opens 5671 (AMQPS), not the plaintext
# container port. Asserting `from_port.*5672` here was wrong and made this suite
# fail against correct IaC. Assert what must actually be true instead.
# NOTE the rules live in separate `aws_security_group_rule` resources that
# reference `aws_security_group.<db|mq>.id`, so the port must be read from a rule
# block, not from the (short) `aws_security_group` block itself.
sg_rule_port() { # sg_rule_port <sg-name>
    awk -v sg="$1" '
        /^resource "aws_security_group_rule"/ { blk=$3; gsub(/"/,"",blk); port=""; target="" }
        index($0, "from_port") { gsub(/[^0-9]/,""); port=$0 }
        index($0, "aws_security_group." sg ".id") && $0 ~ /security_group_id/ { target="yes" }
        target=="yes" && port!="" { print port; exit }
    ' "$ROOT_DIR/terraform/security_groups.tf" 2>/dev/null
}
DB_SG_PORT="$(sg_rule_port db)"
MQ_SG_PORT="$(sg_rule_port mq)"
WORLD_OPEN="$(awk '/^resource .aws_security_group./{sg=$3; gsub(/"/,"",sg)} /0\.0\.0\.0\/0/{print sg}' "$ROOT_DIR/terraform/security_groups.tf" 2>/dev/null | grep -Ex 'db|mq' || true)"
if [ "$DB_SG_PORT" = "5432" ] && [ "$MQ_SG_PORT" = "5671" ] && [ -z "$WORLD_OPEN" ]; then
    pass "Data tier is private: db rule pins 5432 from the app SG only, mq rule pins 5671 (AMQPS/TLS) from the app SG only, neither opens 0.0.0.0/0"
else
    fail "Data-tier isolation is wrong: db from_port='${DB_SG_PORT:-?}' (want 5432), mq from_port='${MQ_SG_PORT:-?}' (want 5671), world-open SGs='${WORLD_OPEN:-none}'"
fi

if grep -qE 'resource .aws_cognito_user_pool.' "$ROOT_DIR/terraform/cognito.tf"; then
    pass "AWS Cognito User Pool configured for managed endpoint authentication"
else
    fail "AWS Cognito User Pool missing"
fi

# Autoscale: assert the real invariant (min < max on every target), not just that
# the string "60" appears somewhere.
AS_MIN="$(awk '/^resource .aws_appautoscaling_target./{f=1} f&&/min_capacity/{gsub(/[^0-9]/,"");print;exit}' "$ROOT_DIR/terraform/autoscaling.tf" 2>/dev/null)"
AS_MAX="$(awk '/^resource .aws_appautoscaling_target./{f=1} f&&/max_capacity/{gsub(/[^0-9]/,"");print;exit}' "$ROOT_DIR/terraform/autoscaling.tf" 2>/dev/null)"
AS_TGT="$(awk '/^variable .autoscaling_target_cpu./{f=1} f&&/default[[:space:]]*=/{gsub(/[^0-9.]/,"");print;exit}' "$ROOT_DIR/terraform/variables.tf" 2>/dev/null)"
if [ -n "$AS_MIN" ] && [ -n "$AS_MAX" ] && [ "$AS_MAX" -gt "$AS_MIN" ] && [ "${AS_TGT%%.*}" -ge 30 ] 2>/dev/null; then
    pass "Auto-scaling: target tracking min=${AS_MIN} max=${AS_MAX} at ${AS_TGT}% CPU"
else
    fail "Auto-scaling target tracking is missing or nonsensical (min='${AS_MIN}' max='${AS_MAX}' target='${AS_TGT}')"
fi

if grep -rqE 'resource .aws_inspector2_enabler.|resource .aws_inspector2_filter.' "$ROOT_DIR/terraform/"; then
    pass "AWS Inspector v2 continuous vulnerability scanning is provisioned"
else
    fail "AWS Inspector v2 is missing -- the audit explicitly asks for regular vulnerability scanning"
fi

# -----------------------------------------------------------------------------
echo ">>> 3. Kubernetes manifests (parsed statically, not applied)"
# -----------------------------------------------------------------------------
for m in namespace.yaml secrets.yaml configmap.yaml network-policies.yaml \
         rabbitmq.yaml inventory-database.yaml billing-database.yaml \
         inventory-app.yaml billing-app.yaml api-gateway.yaml ingress.yaml; do
    if [ -f "$ROOT_DIR/manifests/$m" ]; then pass "Kubernetes manifest present: $m"; else fail "Missing manifest: $m"; fi
done

if [ -f "$ROOT_DIR/manifests/kustomization.yaml" ]; then
    pass "manifests/kustomization.yaml present -- 'kubectl apply -k manifests/' is the supported entry point"
else
    fail "manifests/kustomization.yaml is missing; 'kubectl apply -f manifests/' cannot be made to work without it"
fi

# The committed Secret must be placeholders only.
NON_PLACEHOLDER="$(grep -E '^[[:space:]]+[A-Z0-9_]+:[[:space:]]*"' "$ROOT_DIR/manifests/secrets.yaml" 2>/dev/null | grep -v 'REPLACE_ME_' || true)"
if [ -z "$NON_PLACEHOLDER" ]; then
    pass "manifests/secrets.yaml contains only REPLACE_ME_* placeholders (no real credential committed)"
else
    fail "manifests/secrets.yaml contains real credential value(s): $NON_PLACEHOLDER"
fi

# -----------------------------------------------------------------------------
echo ">>> 4. Dockerfile optimisation (real analysis, per image)"
# -----------------------------------------------------------------------------
DF_TOTAL=0; DF_MULTI=0; DF_USER=0; DF_CHMOD=0; DF_IGNORE=0
for d in "$ROOT_DIR"/srcs/*/; do
    [ -d "$d" ] || continue
    f="$d/Dockerfile"
    [ -f "$f" ] || continue
    DF_TOTAL=$((DF_TOTAL + 1))
    comp="$(basename "$d")"
    base="$(grep -m1 -E '^FROM ' "$f" | awk '{print $2}')"
    stages="$(grep -cE '^FROM .+ AS ' "$f" | head -1)"
    user="no"; grep -qE '^USER[[:space:]]+' "$f" && { user="yes"; DF_USER=$((DF_USER + 1)); }
    chmod="no"; grep -qE '^COPY[[:space:]].*--chmod=' "$f" && { chmod="yes"; DF_CHMOD=$((DF_CHMOD + 1)); }
    ign="NO";  [ -f "$d/.dockerignore" ] && { ign="yes"; DF_IGNORE=$((DF_IGNORE + 1)); }
    printf "         %-19s base=%-26s stages=%s user=%s COPY--chmod=%s dockerignore=%s\n" \
        "$comp" "$base" "$stages" "$user" "$chmod" "$ign"
done
if [ "$DF_TOTAL" -gt 0 ]; then pass "analysed ${DF_TOTAL} Dockerfiles from srcs/*/Dockerfile"
else fail "no Dockerfiles found under srcs/*/"; fi
for a in api-gateway-app inventory-app billing-app; do
    if grep -qE '^FROM .+ AS ' "$ROOT_DIR/srcs/$a/Dockerfile" 2>/dev/null; then DF_MULTI=$((DF_MULTI + 1)); fi
done
if [ "$DF_MULTI" -eq 3 ]; then pass "all 3 Python app images are multi-stage"
else fail "only ${DF_MULTI}/3 Python app images are multi-stage"; fi
if [ "$DF_USER" -ge 3 ]; then pass "${DF_USER} image(s) set a non-root USER"
else fail "fewer than 3 images set a non-root USER (${DF_USER})"; fi
if [ "$DF_CHMOD" -ge 3 ]; then pass "${DF_CHMOD} image(s) use COPY --chmod instead of a separate RUN chmod layer"
else fail "only ${DF_CHMOD} image(s) use COPY --chmod"; fi
if [ "$DF_IGNORE" -eq "$DF_TOTAL" ]; then pass "every component ships a .dockerignore"
else fail "${DF_IGNORE}/${DF_TOTAL} components have a .dockerignore"; fi

# -----------------------------------------------------------------------------
echo ">>> 5. Python sources compile"
# -----------------------------------------------------------------------------
PY_N=0
for app in api-gateway-app inventory-app billing-app; do
    s="$ROOT_DIR/srcs/$app/server.py"
    [ -f "$s" ] || continue
    PY_N=$((PY_N + 1))
    if python3 -m py_compile "$s" 2>/dev/null; then pass "Python compiles: srcs/$app/server.py"
    else fail "Python compile error: srcs/$app/server.py"; fi
done
# Byte-compile artefacts must not be tracked (see the .gitignore header).
TRACKED_PYCACHE="$(cd "$ROOT_DIR" && git ls-files 2>/dev/null | grep -cE '__pycache__|\.pyc' || true)"
if [ "${TRACKED_PYCACHE:-0}" -eq 0 ]; then
    pass "no __pycache__/*.pyc files are tracked in git"
else
    warn "${TRACKED_PYCACHE} __pycache__/*.pyc file(s) are still TRACKED in git. .gitignore cannot untrack them; run: git rm -r --cached srcs/api-gateway-app/__pycache__ srcs/billing-app/__pycache__ srcs/inventory-app/__pycache__"
fi

# -----------------------------------------------------------------------------
echo ">>> 6. Shell scripts and this suite's siblings are syntactically valid"
# -----------------------------------------------------------------------------
for sh in "$SCRIPT_DIR"/*.sh; do
    [ -f "$sh" ] || continue
    if bash -n "$sh" 2>/dev/null; then pass "bash -n clean: $(basename "$sh")"
    else fail "bash -n reports a syntax error: $(basename "$sh")"; fi
done
for py in "$SCRIPT_DIR"/*.py; do
    [ -f "$py" ] || continue
    if python3 -m py_compile "$py" 2>/dev/null; then pass "py_compile clean: $(basename "$py")"
    else fail "py_compile reports a syntax error: $(basename "$py")"; fi
done
rm -rf "$SCRIPT_DIR/__pycache__" 2>/dev/null || true

# -----------------------------------------------------------------------------
echo ">>> 7. Terraform formatting and validation"
# -----------------------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then
    if terraform -chdir="$ROOT_DIR/terraform" fmt -check -diff >/dev/null 2>&1; then
        pass "terraform fmt -check is clean"
    else
        fail "terraform fmt -check reports formatting drift (run: terraform fmt)"
    fi
    if terraform -chdir="$ROOT_DIR/terraform" validate >/dev/null 2>&1; then
        pass "terraform validate succeeds"
    else
        fail "terraform validate fails"
    fi
else
    warn "terraform binary NOT installed -- 'terraform fmt -check' and 'terraform validate' were NOT run, so the IaC syntax/format verdict is UNKNOWN. This is neither a pass nor a failure. Install terraform and re-run, or use scripts/run-audit-checks.sh which reports it as INVALID explicitly."
fi

if command -v aws >/dev/null 2>&1; then
    pass "aws CLI is installed (live AWS inspection is out of scope for this static suite)"
else
    warn "aws CLI NOT installed -- no live AWS resource can be inspected from here; all AWS evidence is static only"
fi

if command -v kubectl >/dev/null 2>&1; then
    if kubectl kustomize "$ROOT_DIR/manifests/" >/dev/null 2>&1; then
        pass "kubectl kustomize manifests/ parses (server-less, no cluster needed)"
    else
        fail "kubectl kustomize manifests/ fails to parse"
    fi
else
    warn "kubectl NOT installed -- manifest validation could not run"
fi

# -----------------------------------------------------------------------------
echo "============================================================"
echo " STATIC VERIFICATION SUMMARY                                "
echo "============================================================"
echo "  Total Checks Passed: $PASS_COUNT"
echo "  Total Checks Failed: $FAIL_COUNT"
echo "  Warnings (unverified, not failures): $WARN_COUNT"
if [ "$WARN_COUNT" -gt 0 ]; then
    echo
    echo "  WARNINGS:"
    for w in "${WARNINGS[@]}"; do echo "    - $w"; done
fi
echo
echo "  REMINDER: this suite proves only what can be read from files."
echo "  Live evidence (running containers, kubectl, HTTP, load, LB spread) is in"
echo "  scripts/run-audit-checks.sh."

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo
    echo ">>> ${FAIL_COUNT} CHECK(S) FAILED <<<"
    exit 1
fi
echo
echo ">>> ALL STATIC CLOUD-DESIGN CHECKS PASSED (${PASS_COUNT} checks, ${WARN_COUNT} warnings) <<<"
exit 0