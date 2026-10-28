#!/usr/bin/env bash
# Single quotes keep $TOKEN-style placeholders, JMESPath backticks and jq
# $variables literal on purpose.
# shellcheck disable=SC2016
set -uo pipefail

# ==============================================================================
# cloud-design - live AWS demo for the audit (ECS on Fargate)
# ==============================================================================
# One section per live question in docs/cloud-design-questions.md (the IDs V1,
# S2 and so on are those of the table in progress.md). Every command is printed
# before it runs, so the auditor sees the real aws / curl call and its real
# output. The key results are checked and reported as [PASS], [FAIL],
# [WARN] or [SKIP], and the exit code is 1 if any check failed.
#
# SECTIONS
#   verify    V1, V2  ECS services and tasks, target health, recent logs, RDS,
#                     Amazon MQ, /health end to end, and why `docker ps` does
#                     not apply on Fargate
#   lb        V3      target health, LB_REQUESTS requests through API Gateway,
#                     then the per-task split from the ALB access logs in S3
#   lb-split  V3      only the split. ALB delivers its logs every 5 minutes, so
#                     run this again a few minutes after `lb`
#   auth      S2, S3  401 with no token and with a forged one, a real Cognito
#                     token, 200 with it, then the JWT authorizer, the routes
#                     and the user pool
#   movies    F1, F2  POST a movie through API Gateway and GET it back
#   billing   B1, B2  the consumer outage drill: pause billing-app's auto
#                     scaling, stop billing-app, POST an order through API
#                     Gateway, show it waiting in the queue (MessageCount),
#                     start billing-app again, show the order stored and in
#                     the logs, then restore the auto scaling
#   load      O1, O2  the scaling policies, a timed load test through API
#                     Gateway, then the scaling activities and the CPU
#   scaling   O1      only the scaling view; run it again a few minutes after
#                     `load`, because scale-out follows the CPU alarm
#   security  S1      HTTPS, the internal ALB, secured routes, database access
#                     restricted to the VPC, encryption, secrets, image scans
#   all               verify lb auth movies billing security load
#
# WHAT CHANGES STATE
#   `movies` creates one movie. `lb` and `load` send requests (API Gateway bills
#   $1 per million) and `load` can make the services scale out and back in.
#   `billing` stops billing-app for a few minutes and creates one order; while
#   the consumers are down, the consumers-below-min alarm fires and emails the
#   alerts topic. The drill puts billing-app's task count, minimum, maximum and
#   suspended state back as it found them, also when it fails or is interrupted
#   (Ctrl-C). Nothing else writes anything. No secret is printed: the ID token,
#   the demo password, the client secret and the SECRET_HASH appear as $TOKEN,
#   $PASSWORD, $SECRET and $SECRET_HASH.
#
# USAGE
#   export AWS_PROFILE=cloud-design      # README: "Shared AWS account"
#   scripts/aws-demo.sh verify           # one section
#   scripts/aws-demo.sh auth movies      # several, in this order
#   scripts/aws-demo.sh --pause all      # wait for Enter before each command
#   LB_REQUESTS=200 scripts/aws-demo.sh lb
#   LOAD_DURATION=420 LOAD_CONCURRENCY=48 scripts/aws-demo.sh load
#
# ENVIRONMENT
#   AWS_PROFILE       must equal DEMO_PROFILE (default cloud-design), because
#                     the account is shared; DEMO_PROFILE= (empty) turns the
#                     check off for other credentials
#   REGION            default: the region in the API Gateway invoke URL
#   LB_REQUESTS       requests sent by `lb` (default 100)
#   LOAD_DURATION     seconds of load in `load` (default 300)
#   LOAD_CONCURRENCY  parallel workers in `load` (default 32)
#   LOAD_PATH         path the load hits (default /api/movies, with the token)
#   DRILL_WAIT        seconds `billing` waits at each step: the tasks stopping,
#                     the queued message in CloudWatch, the tasks starting, the
#                     order stored, the queue drained (default 420)
#
# NEEDS: aws (v2), terraform (reads the outputs of terraform/), jq, curl;
#        openssl for the Cognito token, python3 for `load`, zcat for `lb`.
#
# EXIT: 0 every check passed (warnings and skips allowed), 1 a check failed or
#       a prerequisite is missing, 2 bad usage.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

DEMO_PROFILE="${DEMO_PROFILE-cloud-design}"
LB_REQUESTS="${LB_REQUESTS:-100}"
LOAD_DURATION="${LOAD_DURATION:-300}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-32}"
LOAD_PATH="${LOAD_PATH:-/api/movies}"
DRILL_WAIT="${DRILL_WAIT:-420}"
PAUSE=0
ALL_SECTIONS=(verify lb auth movies billing security load)
KNOWN_SECTIONS=" verify lb lb-split auth movies billing load scaling security all "

usage() { awk '/^# =+$/ { n++ } n >= 1 { print } n == 3 { exit }' "${BASH_SOURCE[0]}"; }

SECTIONS=()
add_section() {
  local s
  for s in "${SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done
  SECTIONS+=("$1")
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pause) PAUSE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)
      case "${KNOWN_SECTIONS}" in
        *" $1 "*) ;;
        *) echo "unknown section: $1 (try --help)" >&2; exit 2 ;;
      esac
      if [ "$1" = all ]; then
        for s in "${ALL_SECTIONS[@]}"; do add_section "$s"; done
      else
        add_section "$1"
      fi ;;
  esac
  shift
done
if [ "${#SECTIONS[@]}" -eq 0 ]; then usage >&2; exit 2; fi
if [ "${PAUSE}" -eq 1 ] && ! { : </dev/tty; } 2>/dev/null; then
  echo "--pause waits for Enter on the terminal, and there is none here" >&2; exit 2
fi
for n in LB_REQUESTS LOAD_DURATION LOAD_CONCURRENCY DRILL_WAIT; do
  case "${!n}" in
    ''|*[!0-9]*|0) echo "${n} must be a positive whole number, got '${!n}'" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
PASS=0; FAIL=0; WARN=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $*"; }
note() { echo "  $*"; }
die()  { echo "[FATAL] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed: $2"; }

section() {
  echo
  echo "=================================================================="
  echo " $1"
  shift
  local q
  for q in "$@"; do echo "   $q"; done
  echo "=================================================================="
}

# Secret values never reach the screen: they are replaced by their names.
SECRET_NAMES=(); SECRET_VALUES=()
add_secret() { if [ -n "$2" ]; then SECRET_NAMES+=("$1"); SECRET_VALUES+=("$2"); fi; }
mask() {
  local s="$1" i
  for i in "${!SECRET_VALUES[@]}"; do s="${s//"${SECRET_VALUES[$i]}"/"${SECRET_NAMES[$i]}"}"; done
  printf '%s' "$s"
}

# Print an argument the way you would type it in a shell.
quote_arg() {
  case "$1" in
    '') printf "''" ;;
    *[!A-Za-z0-9_@%+=:,./-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
    *) printf '%s' "$1" ;;
  esac
}
# An argument that carries a secret is shown in double quotes, so a pasted copy
# expands $TOKEN and the others.
fmt_cmd() {
  local out="" a m
  for a in "$@"; do
    m="$(mask "$a")"
    if [ "$m" != "$a" ]; then out+="\"${m}\" "; else out+="$(quote_arg "$a") "; fi
  done
  printf '%s' "${out% }"
}

pause() {
  if [ "${PAUSE}" -eq 1 ]; then read -r -p "  (Enter to run) " _ </dev/tty || true; fi
  return 0
}

# cap CMD...      print the command, run it, print and keep its stdout in OUT
# capd TEXT CMD.. the same, but print TEXT instead of the command line
# QUIET=1 keeps the output in OUT without printing it.
OUT=""
capd() {
  local text="$1" rc
  shift
  echo
  echo "\$ ${text}"
  pause
  OUT="$("$@")"
  rc=$?
  if [ "${QUIET:-0}" != 1 ] && [ -n "${OUT}" ]; then mask "${OUT}"; echo; fi
  return "${rc}"
}
cap() { capd "$(fmt_cmd "$@")" "$@"; }
jqo() { printf '%s' "${OUT}" | jq -r "$@" 2>/dev/null; }
jqc() { printf '%s' "${OUT}" | jq -e "$@" >/dev/null 2>&1; }
# ago MINUTES: an ISO time that many minutes back (GNU date, then BSD date).
ago() { date -u -d "-$1 minutes" +%FT%TZ 2>/dev/null || date -u -v-"$1"M +%FT%TZ; }

TMP="$(mktemp -d)"

# While the billing drill runs, billing-app may be at 0 tasks with its auto
# scaling paused. If the script stops for any reason before the drill's last
# step (a failed command, `die`, Ctrl-C), the EXIT trap puts both back.
DRILL_ACTIVE=0; DRILL_DESIRED=""; DRILL_MIN=""; DRILL_MAX=""; DRILL_SUSPENDED=""
# The three suspended flags as one comparable JSON value.
SUSPENDED_JQ='.suspended // {} | [.DynamicScalingInSuspended, .DynamicScalingOutSuspended, .ScheduledScalingSuspended] | map(. // false)'
drill_restore() {
  [ "${DRILL_ACTIVE}" -eq 1 ] || return 0
  DRILL_ACTIVE=0
  echo
  echo "[RESTORE] the billing drill did not finish: putting billing-app back as it was"
  echo "\$ aws ecs update-service --cluster ${CLUSTER} --service ${SVC_BIL} --desired-count ${DRILL_DESIRED}"
  aws ecs update-service --cluster "${CLUSTER}" --service "${SVC_BIL}" \
    --desired-count "${DRILL_DESIRED}" >/dev/null \
    || echo "[RESTORE] update-service failed: run the command above by hand"
  echo "\$ aws application-autoscaling register-scalable-target --service-namespace ecs --scalable-dimension ecs:service:DesiredCount --resource-id service/${CLUSTER}/${SVC_BIL} --min-capacity ${DRILL_MIN} --max-capacity ${DRILL_MAX} --suspended-state ${DRILL_SUSPENDED}"
  aws application-autoscaling register-scalable-target --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount --resource-id "service/${CLUSTER}/${SVC_BIL}" \
    --min-capacity "${DRILL_MIN}" --max-capacity "${DRILL_MAX}" \
    --suspended-state "${DRILL_SUSPENDED}" >/dev/null \
    || echo "[RESTORE] register-scalable-target failed: run the command above by hand"
}
on_exit() { drill_restore; rm -rf "${TMP}"; }
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

# http METHOD URL [TOKEN] [JSON]: print the curl call, run it, set CODE + BODY.
CODE=""; BODY=""
http() {
  local method="$1" url="$2" token="${3:-}" json="${4:-}"
  local args=(-sS -m 20 -X "${method}")
  [ -n "${token}" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "${json}" ] && args+=(-H 'Content-Type: application/json' -d "${json}")
  echo
  echo "\$ $(fmt_cmd curl "${args[@]}" "${url}")"
  pause
  CODE="$(curl "${args[@]}" -o "${TMP}/body" -w '%{http_code}' "${url}")" || CODE="${CODE:-000}"
  BODY="$(cat "${TMP}/body" 2>/dev/null)"
  local shown="${BODY:0:700}"
  [ "${#BODY}" -gt 700 ] && shown="${shown} ... (${#BODY} bytes in total)"
  [ -n "${shown}" ] && mask "${shown}" && echo
  echo "  -> HTTP ${CODE}"
}
expect_code() { # WANT WHAT
  if [ "${CODE}" = "$1" ]; then ok "$2: HTTP ${CODE}"; else bad "$2: expected HTTP $1, got ${CODE}"; fi
}

# ------------------------------------------------------------------------------
# Preflight: tools, credentials, outputs
# ------------------------------------------------------------------------------
need aws "AWS CLI v2"
need terraform "reads the stack outputs in terraform/"
need jq "parses the AWS answers"
need curl "calls API Gateway"
export AWS_PAGER=""

if [ -n "${DEMO_PROFILE}" ] && [ "${AWS_PROFILE:-}" != "${DEMO_PROFILE}" ]; then
  die "AWS_PROFILE is '${AWS_PROFILE:-<unset>}', expected '${DEMO_PROFILE}'. The AWS account
        is shared with another project (README: \"Shared AWS account: one project at a
        time\"). Run: export AWS_PROFILE=${DEMO_PROFILE}   (or DEMO_PROFILE= for other credentials)"
fi

TF_OUT="$(terraform -chdir="${TF_DIR}" output -json 2>/dev/null)" \
  || die "'terraform output' failed in terraform/ (no state here? run scripts/deploy.sh first)"
[ "$(printf '%s' "${TF_OUT}" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null \
  || die "terraform/ has no outputs: the stack is not deployed (scripts/deploy.sh)"
tfo() { printf '%s' "${TF_OUT}" | jq -r --arg k "$1" '.[$k].value // empty | if type == "object" or type == "array" then tojson else . end'; }

API="$(tfo api_gateway_invoke_url)"
[ -n "${API}" ] || die "no api_gateway_invoke_url output"
API_ID="$(printf '%s' "${API}" | sed -nE 's#^https?://([^.]+)\.execute-api\..*#\1#p')"
REGION="${REGION:-$(printf '%s' "${API}" | sed -nE 's#^https?://[^.]+\.execute-api\.([a-z0-9-]+)\.amazonaws\.com.*#\1#p')}"
[ -n "${REGION}" ] || die "could not read the region from ${API}; set REGION"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"

CLUSTER="$(tfo ecs_cluster_name)"
SVC_GW="$(printf '%s' "${TF_OUT}" | jq -r '.ecs_service_names.value["api-gateway"] // empty')"
SVC_INV="$(printf '%s' "${TF_OUT}" | jq -r '.ecs_service_names.value["inventory-app"] // empty')"
SVC_BIL="$(printf '%s' "${TF_OUT}" | jq -r '.ecs_service_names.value["billing-app"] // empty')"
[ -n "${CLUSTER}" ] && [ -n "${SVC_GW}" ] && [ -n "${SVC_INV}" ] && [ -n "${SVC_BIL}" ] \
  || die "missing ecs_cluster_name / ecs_service_names outputs"
NAME_PREFIX="${CLUSTER%-ecs-cluster}"
ECR_REGISTRY="$(tfo ecr_registry_url)"
ACCOUNT_TF="${ECR_REGISTRY%%.*}"

echo "=================================================================="
echo " cloud-design: live AWS demo"
echo "=================================================================="
echo " sections : ${SECTIONS[*]}"
echo " API      : ${API}"
echo " region   : ${REGION}"
echo " cluster  : ${CLUSTER}"
echo " run id   : ${RUN_ID}"

section "Identity" "Who runs this demo, in which account. The account is shared, so this comes first."
if ! cap aws sts get-caller-identity --output json; then
  die "aws sts get-caller-identity failed: no valid credentials for profile '${AWS_PROFILE:-<default>}'"
fi
CALLER_ACCOUNT="$(jqo .Account)"
if [ "${CALLER_ACCOUNT}" = "${ACCOUNT_TF}" ]; then
  ok "the credentials belong to account ${CALLER_ACCOUNT}, the account this Terraform state deployed to"
else
  die "the credentials belong to account ${CALLER_ACCOUNT}, but the stack is in account ${ACCOUNT_TF:-<unknown>}"
fi

# ------------------------------------------------------------------------------
# Shared pieces
# ------------------------------------------------------------------------------
TOKEN=""; TOKEN_FAILED=0
jwt_claims() {
  local p="${1#*.}"
  p="${p%%.*}"
  p="$(printf '%s' "${p}" | tr '_-' '/+')"
  case $(( ${#p} % 4 )) in 2) p="${p}==" ;; 3) p="${p}=" ;; esac
  printf '%s' "${p}" | base64 -d 2>/dev/null \
    | jq -c '{iss, token_use, aud, email, expires: (.exp | todate)}' 2>/dev/null
}
# get_token: a Cognito ID token for the demo user, through the confidential
# demo client (README "Obtain a JWT"). Returns 1 when there is no demo user.
get_token() {
  [ -n "${TOKEN}" ] && return 0
  [ "${TOKEN_FAILED}" -eq 1 ] && return 1
  TOKEN_FAILED=1
  need openssl "computes the Cognito SECRET_HASH"
  local pool cid email pass secret hash params claims
  pool="$(tfo cognito_user_pool_id)"
  cid="$(tfo cognito_demo_client_id)"
  email="$(tfo cognito_demo_user_email)"
  pass="$(tfo cognito_demo_user_password)"
  if [ -z "${cid}" ] || [ -z "${email}" ] || [ -z "${pass}" ]; then
    note "no demo Cognito client or user (enable_demo_cognito_user = false)."
    note "Log in through the hosted UI instead: $(tfo cognito_hosted_ui_url)"
    return 1
  fi
  add_secret '$PASSWORD' "${pass}"
  echo
  echo "\$ aws cognito-idp describe-user-pool-client --user-pool-id ${pool} --client-id ${cid} --query UserPoolClient.ClientSecret --output text    # kept in \$SECRET"
  pause
  secret="$(aws cognito-idp describe-user-pool-client --user-pool-id "${pool}" --client-id "${cid}" \
            --query UserPoolClient.ClientSecret --output text)" || return 1
  add_secret '$SECRET' "${secret}"
  hash="$(printf '%s' "${email}${cid}" | openssl dgst -sha256 -hmac "${secret}" -binary | base64)"
  add_secret '$SECRET_HASH' "${hash}"
  echo "\$ SECRET_HASH=\$(printf '%s' '${email}${cid}' | openssl dgst -sha256 -hmac \"\$SECRET\" -binary | base64)"
  params="$(jq -cn --arg u "${email}" --arg p "${pass}" --arg h "${hash}" '{USERNAME: $u, PASSWORD: $p, SECRET_HASH: $h}')"
  echo
  echo "\$ aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id ${cid} --auth-parameters '{\"USERNAME\":\"${email}\",\"PASSWORD\":\"\$PASSWORD\",\"SECRET_HASH\":\"\$SECRET_HASH\"}' --query AuthenticationResult.IdToken --output text    # kept in \$TOKEN"
  pause
  TOKEN="$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "${cid}" \
           --auth-parameters "${params}" --query AuthenticationResult.IdToken --output text)" || TOKEN=""
  if [ -z "${TOKEN}" ] || [ "${TOKEN}" = None ]; then
    TOKEN=""
    note "Cognito returned no ID token (a challenge instead, or wrong credentials)."
    return 1
  fi
  add_secret '$TOKEN' "${TOKEN}"
  TOKEN_FAILED=0
  claims="$(jwt_claims "${TOKEN}")"
  note "token claims (the payload only; the signature is not shown): ${claims:-<could not decode>}"
  return 0
}

describe_services() { # SERVICE...
  cap aws ecs describe-services --cluster "${CLUSTER}" --services "$@" \
    --query 'services[].{name:serviceName,status:status,desired:desiredCount,running:runningCount,pending:pendingCount,rollout:deployments[0].rolloutState,targetGroups:loadBalancers[].targetGroupArn}' \
    --output json
}

# target_health TG_ARN LABEL MIN_TARGETS
target_health() {
  if ! cap aws elbv2 describe-target-health --target-group-arn "$1" \
       --query 'TargetHealthDescriptions[].{target:Target.Id,port:Target.Port,state:TargetHealth.State,reason:TargetHealth.Reason}' \
       --output json; then
    bad "could not read the target health of $2"
    return
  fi
  local total healthy
  total="$(jqo 'length')"
  healthy="$(jqo '[.[] | select(.state == "healthy")] | length')"
  if [ "${healthy:-0}" -ge "$3" ] && [ "${healthy}" = "${total}" ]; then
    ok "$2: ${healthy} of ${total} targets healthy"
  else
    bad "$2: ${healthy:-0} of ${total:-0} targets healthy (want at least $3, all healthy)"
  fi
}

TG_GW=""; TG_BIL=""
load_target_groups() {
  [ -n "${TG_GW}" ] && return 0
  local out
  out="$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SVC_GW}" "${SVC_BIL}" \
          --query 'services[].{name:serviceName,tg:loadBalancers[0].targetGroupArn}' --output json 2>/dev/null)"
  TG_GW="$(printf '%s' "${out}" | jq -r --arg s "${SVC_GW}" '.[] | select(.name == $s) | .tg // empty')"
  TG_BIL="$(printf '%s' "${out}" | jq -r --arg s "${SVC_BIL}" '.[] | select(.name == $s) | .tg // empty')"
  [ -n "${TG_GW}" ]
}

# service_tasks SERVICE: running tasks with their AZ and private IP, into OUT.
service_tasks() {
  local arns
  arns="$(aws ecs list-tasks --cluster "${CLUSTER}" --service-name "$1" --desired-status RUNNING \
           --query 'taskArns' --output text 2>/dev/null)"
  if [ -z "${arns}" ] || [ "${arns}" = None ]; then OUT="[]"; return 1; fi
  # shellcheck disable=SC2086
  capd "aws ecs describe-tasks --cluster ${CLUSTER} --tasks \$(aws ecs list-tasks --cluster ${CLUSTER} --service-name $1 --query taskArns --output text) --query 'tasks[].{task:taskArn,az:availabilityZone,ip:attachments[0].details[?name==\`privateIPv4Address\`]|[0].value,last:lastStatus,health:healthStatus}' --output json" \
    aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${arns} \
    --query 'tasks[].{task:taskArn,az:availabilityZone,ip:attachments[0].details[?name==`privateIPv4Address`]|[0].value,last:lastStatus,health:healthStatus}' \
    --output json
}

show_scaling_config() {
  cap aws application-autoscaling describe-scalable-targets --service-namespace ecs \
    --query "ScalableTargets[?starts_with(ResourceId, \`service/${CLUSTER}/\`)].{resource:ResourceId,min:MinCapacity,max:MaxCapacity,suspended:SuspendedState}" \
    --output json
  cap aws application-autoscaling describe-scaling-policies --service-namespace ecs \
    --query "ScalingPolicies[?starts_with(ResourceId, \`service/${CLUSTER}/\`)].{resource:ResourceId,policy:PolicyName,type:PolicyType,target:TargetTrackingScalingPolicyConfiguration.TargetValue,predefinedMetric:TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType,customMetric:TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.MetricName}" \
    --output json
  # The alarms Application Auto Scaling made for the target tracking policies:
  # AlarmHigh drives scale-out, AlarmLow scale-in.
  cap aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-service/${CLUSTER}/" \
    --query 'MetricAlarms[].{alarm:AlarmName,state:StateValue,metric:MetricName,threshold:Threshold,periodSeconds:Period,evaluationPeriods:EvaluationPeriods,datapointsToAlarm:DatapointsToAlarm}' \
    --output table
}

desired_counts() { # prints "gw inv"
  aws ecs describe-services --cluster "${CLUSTER}" --services "${SVC_GW}" "${SVC_INV}" \
    --query 'services[].[serviceName,desiredCount]' --output json 2>/dev/null \
    | jq -r --arg g "${SVC_GW}" --arg i "${SVC_INV}" \
        '(map({(.[0]): .[1]}) | add) as $m | "\($m[$g] // 0) \($m[$i] // 0)"'
}

show_scaling_after() {
  local svc start end
  start="$(ago 20)"
  end="$(date -u +%FT%TZ)"
  for svc in "${SVC_GW}" "${SVC_INV}"; do
    cap aws application-autoscaling describe-scaling-activities --service-namespace ecs \
      --resource-id "service/${CLUSTER}/${svc}" --max-items 5 \
      --query 'ScalingActivities[].{start:StartTime,status:StatusCode,description:Description}' --output json
    cap aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization \
      --dimensions "Name=ClusterName,Value=${CLUSTER}" "Name=ServiceName,Value=${svc}" \
      --start-time "${start}" --end-time "${end}" --period 60 --statistics Average Maximum \
      --query 'sort_by(Datapoints,&Timestamp)[].{time:Timestamp,average:Average,maximum:Maximum}' --output table
  done
  describe_services "${SVC_GW}" "${SVC_INV}" "${SVC_BIL}"
}

# ------------------------------------------------------------------------------
# Sections
# ------------------------------------------------------------------------------
sec_verify() {
  section "Verify the deployment (V1, V2)" \
    "Q: show the aws cli and ECS commands that verify the deployment" \
    "Q: are all the microservices running, with no errors or connectivity issues?"

  if describe_services "${SVC_GW}" "${SVC_INV}" "${SVC_BIL}"; then
    if jqc 'length == 3 and all(.[]; .status == "ACTIVE" and .desired >= 1 and .running == .desired)'; then
      ok "all three ECS services are ACTIVE and run their desired number of tasks"
    else
      bad "a service is not ACTIVE or runs fewer tasks than desired (see above)"
    fi
    if jqc 'all(.[]; .rollout == "COMPLETED")'; then
      ok "no deployment is in progress (every rollout COMPLETED)"
    else
      warn "a deployment is still rolling out; wait for 'aws ecs wait services-stable'"
    fi
  else
    bad "aws ecs describe-services failed"
  fi

  local svc label azs
  for svc in "${SVC_GW}" "${SVC_INV}" "${SVC_BIL}"; do
    label="${svc#"${NAME_PREFIX}-"}"
    if service_tasks "${svc}"; then
      if jqc 'length >= 1 and all(.[]; .last == "RUNNING")'; then
        ok "${label}: $(jqo 'length') task(s) RUNNING"
      else
        bad "${label}: a task is not RUNNING"
      fi
      if jqc 'all(.[]; .health == "HEALTHY")'; then
        ok "${label}: every task passes its container health check"
      else
        warn "${label}: a task health status is not HEALTHY yet ($(jqo '[.[].health] | join(", ")'))"
      fi
      azs="$(jqo '[.[].az] | unique | length')"
      if [ "${azs:-0}" -ge 2 ]; then
        ok "${label}: tasks spread over ${azs} Availability Zones"
      else
        warn "${label}: all tasks are in one Availability Zone"
      fi
    else
      bad "${label}: no running tasks"
    fi
  done

  if load_target_groups; then
    target_health "${TG_GW}" "api-gateway target group" 2
    [ -n "${TG_BIL}" ] && target_health "${TG_BIL}" "billing-app target group (GET /api/billing/orders)" 1
  else
    bad "could not find the target groups of the api-gateway and billing-app services"
  fi

  local app errors
  for app in api-gateway inventory-app billing-app; do
    if QUIET=1 capd "aws logs tail /aws/microservices/${NAME_PREFIX}/${app} --since 10m | tail -n 12" \
         aws logs tail "/aws/microservices/${NAME_PREFIX}/${app}" --since 10m; then
      if [ -n "${OUT}" ]; then mask "$(printf '%s\n' "${OUT}" | tail -n 12)"; echo; fi
      errors="$(printf '%s\n' "${OUT}" | grep -cE 'Traceback|ERROR|CRITICAL')"
      if [ "${errors}" -eq 0 ]; then
        ok "${app}: no error lines in the last 10 minutes of logs"
      else
        warn "${app}: ${errors} error line(s) in the last 10 minutes of logs (read them above)"
      fi
    else
      bad "${app}: could not read the log group"
    fi
  done

  if cap aws rds describe-db-instances \
       --filters "Name=db-instance-id,Values=${NAME_PREFIX}-inventory-db,${NAME_PREFIX}-billing-db" \
       --query 'DBInstances[].{id:DBInstanceIdentifier,status:DBInstanceStatus,engine:EngineVersion,multiAZ:MultiAZ,public:PubliclyAccessible,encrypted:StorageEncrypted}' \
       --output json; then
    if jqc 'length == 2 and all(.[]; .status == "available")'; then
      ok "both RDS PostgreSQL instances are available"
    else
      bad "an RDS instance is missing or not available"
    fi
    if jqc 'all(.[]; .multiAZ == true)'; then ok "both databases are Multi-AZ"; else bad "a database is not Multi-AZ"; fi
  else
    bad "aws rds describe-db-instances failed"
  fi

  local broker
  broker="$(tfo amazon_mq_broker_id)"
  if cap aws mq describe-broker --broker-id "${broker}" \
       --query '{name:BrokerName,state:BrokerState,mode:DeploymentMode,engine:EngineVersion,instance:HostInstanceType,public:PubliclyAccessible}' \
       --output json; then
    if jqc '.state == "RUNNING"'; then ok "the Amazon MQ broker is RUNNING"; else bad "the broker is not RUNNING"; fi
  else
    bad "aws mq describe-broker failed"
  fi

  http GET "${API}/health"
  expect_code 200 "end to end: API Gateway, VPC Link, internal ALB, api-gateway task"

  echo
  note "docker ps: Fargate has no container host to log in to, so the task list above is"
  note "the equivalent. For a shell inside a running task (needs the Session Manager plugin):"
  note "  aws ecs execute-command --cluster ${CLUSTER} --task <task-id> --container api-gateway --interactive --command sh"
  note "docker ps on this machine shows the same images in the local compose stack (make up)."
}

# lb_split MARKER: count today's logged requests per target. `lb` passes its own
# lbdemo=<run id>; `lb-split` runs later with a new run id, so it passes lbdemo=.
lb_split() {
  local marker="$1" bucket day prefix files split marked total
  bucket="$(tfo artifact_bucket_name)"
  if [ -z "${bucket}" ]; then
    skip "no artifact bucket (enable_artifact_bucket = false), so no ALB access logs"
    return
  fi
  need zcat "reads the gzip ALB access logs"
  day="$(date -u +%Y/%m/%d)"
  prefix="s3://${bucket}/alb-access-logs/AWSLogs/${ACCOUNT_TF}/elasticloadbalancing/${REGION}/${day}/"
  mkdir -p "${TMP}/alb-logs"
  echo
  echo "\$ $(fmt_cmd aws s3 sync "${prefix}" /tmp/alb-logs --quiet)"
  pause
  if ! aws s3 sync "${prefix}" "${TMP}/alb-logs" --quiet; then
    warn "could not read the ALB access logs from ${prefix}"
    return
  fi
  files="$(find "${TMP}/alb-logs" -name '*.log.gz' | wc -l | tr -d ' ')"
  note "${files} access log file(s) for ${day} (UTC)"
  if [ "${files}" -eq 0 ]; then
    warn "no access logs yet: ALB delivers them every 5 minutes; run: scripts/aws-demo.sh lb-split"
    return
  fi
  marked="$(find "${TMP}/alb-logs" -name '*.log.gz' -exec zcat {} + | grep -cF "${marker}")"
  echo
  if [ "${marked}" -gt 0 ]; then
    echo "\$ zcat /tmp/alb-logs/**/*.log.gz | grep -F '${marker}' | awk '{print \$5}' | sort | uniq -c    # requests sent by this script, per target"
    split="$(find "${TMP}/alb-logs" -name '*.log.gz' -exec zcat {} + | grep -F "${marker}" | awk '{print $5}' | sort | uniq -c)"
  else
    echo "\$ zcat /tmp/alb-logs/**/*.log.gz | awk '\$5 ~ /:3000\$/ {print \$5}' | sort | uniq -c    # every request today, per api-gateway target"
    split="$(find "${TMP}/alb-logs" -name '*.log.gz' -exec zcat {} + | awk '$5 ~ /:3000$/ {print $5}' | sort | uniq -c)"
    note "(no requests from this script in the logs yet, so this counts all of today's traffic)"
  fi
  printf '%s\n' "${split}"
  service_tasks "${SVC_GW}" >/dev/null 2>&1 || true
  local tasks_json="${OUT}"
  echo
  note "target -> api-gateway task (only tasks still running can be named):"
  printf '%s\n' "${split}" | while read -r count target; do
    [ -n "${target:-}" ] || continue
    local ip="${target%:*}" t
    t="$(printf '%s' "${tasks_json}" | jq -r --arg ip "${ip}" '.[] | select(.ip == $ip) | "\(.task | split("/") | last) in \(.az)"' 2>/dev/null)"
    note "  ${count} requests -> ${target}  ${t:-(task no longer running)}"
  done
  total="$(printf '%s\n' "${split}" | awk 'NF == 2' | wc -l | tr -d ' ')"
  if [ "${total}" -ge 2 ]; then
    ok "the ALB spread the requests over ${total} api-gateway targets"
  else
    warn "the logged requests reached ${total} target(s); with 2 tasks, send more traffic and run lb-split again"
  fi
}

sec_lb() {
  section "Load balancing (V3)" \
    "Q: is the load balancing configured correctly, effectively distributing traffic across the services?"
  if load_target_groups; then
    target_health "${TG_GW}" "api-gateway target group" 2
  else
    bad "could not find the api-gateway target group"
  fi
  service_tasks "${SVC_GW}" || bad "api-gateway has no running tasks"

  local codes
  echo
  printf '%s\n' "\$ for i in \$(seq ${LB_REQUESTS}); do curl -s -o /dev/null -w '%{http_code}\\n' '${API}/health?lbdemo=${RUN_ID}'; done | sort | uniq -c"
  pause
  codes="$(for _ in $(seq "${LB_REQUESTS}"); do
             curl -s -m 10 -o /dev/null -w '%{http_code}\n' "${API}/health?lbdemo=${RUN_ID}"
           done | sort | uniq -c)"
  printf '%s\n' "${codes}"
  if [ "$(printf '%s\n' "${codes}" | awk '$2 == "200" {print $1}')" = "${LB_REQUESTS}" ]; then
    ok "all ${LB_REQUESTS} requests through API Gateway answered 200"
  else
    bad "not every request answered 200 (see above)"
  fi
  lb_split "lbdemo=${RUN_ID}"
  note "ALB writes its access logs every 5 minutes; this run's requests carry lbdemo=${RUN_ID}."
  note "If they are not counted yet, run: scripts/aws-demo.sh lb-split"
}

sec_lb_split() {
  section "Load balancing (V3): the split from the ALB access logs"
  lb_split "lbdemo="
}

sec_auth() {
  section "Authentication at API Gateway (S2, S3)" \
    "Q: when accessing the API Gateway without valid credentials, is the request rejected?" \
    "Q: show the managed authentication (Cognito) that protects the API Gateway"

  http GET "${API}/api/movies"
  expect_code 401 "no token: the JWT authorizer rejects the request"
  local forged="eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJub2JvZHkifQ.Zm9yZ2Vk"
  http GET "${API}/api/movies" "${forged}"
  expect_code 401 "forged token: the JWT authorizer rejects the request"
  http GET "${API}/health"
  expect_code 200 "GET /health is public by design (ALB health check and uptime monitors)"

  if get_token; then
    ok "Cognito issued an ID token for the demo user (USER_PASSWORD_AUTH)"
    http GET "${API}/api/movies" "${TOKEN}"
    expect_code 200 "valid Cognito token: the request reaches the movies API"
  else
    skip "no Cognito token, so the authenticated call is not shown"
  fi

  if [ -n "${API_ID}" ] && cap aws apigatewayv2 get-authorizers --api-id "${API_ID}" \
       --query 'Items[].{name:Name,type:AuthorizerType,identitySource:IdentitySource,issuer:JwtConfiguration.Issuer,audience:JwtConfiguration.Audience}' \
       --output json; then
    if jqc --arg iss "$(tfo cognito_issuer_url)" 'length >= 1 and all(.[]; .type == "JWT" and .issuer == $iss)'; then
      ok "the authorizer is a JWT authorizer whose issuer is this Cognito user pool"
    else
      bad "the authorizer is not a JWT authorizer for this user pool"
    fi
  else
    bad "aws apigatewayv2 get-authorizers failed"
  fi

  if [ -n "${API_ID}" ] && cap aws apigatewayv2 get-routes --api-id "${API_ID}" \
       --query 'Items[].{route:RouteKey,auth:AuthorizationType}' --output json; then
    if jqc '[.[] | select(.route | test("/api/"))] | length >= 1 and all(.[]; .auth == "JWT")'; then
      ok "every /api/* route requires the JWT authorizer"
    else
      bad "an /api/* route does not require the JWT authorizer"
    fi
  else
    bad "aws apigatewayv2 get-routes failed"
  fi

  cap aws cognito-idp describe-user-pool --user-pool-id "$(tfo cognito_user_pool_id)" \
    --query 'UserPool.{name:Name,id:Id,usernameAttributes:UsernameAttributes,mfa:MfaConfiguration,passwordPolicy:Policies.PasswordPolicy,estimatedUsers:EstimatedNumberOfUsers}' \
    --output json || bad "aws cognito-idp describe-user-pool failed"
}

sec_movies() {
  section "API functionality through API Gateway (F1, F2)" \
    "Q: create a movie with a POST request through the API Gateway" \
    "Q: retrieve the movies with a GET request; does the response contain the expected data?"
  if ! get_token; then
    skip "no Cognito token, so the movies API cannot be called"
    return
  fi
  local title body id
  title="Audit demo ${RUN_ID}"
  body="$(jq -cn --arg t "${title}" '{title: $t, description: "Created through API Gateway by scripts/aws-demo.sh"}')"
  http POST "${API}/api/movies" "${TOKEN}" "${body}"
  expect_code 200 "POST /api/movies created the movie"
  id="$(printf '%s' "${BODY}" | jq -r '.id // empty' 2>/dev/null)"
  if [ -z "${id}" ]; then
    bad "the POST response carries no id"
    return
  fi
  note "new movie id: ${id}"

  http GET "${API}/api/movies" "${TOKEN}"
  expect_code 200 "GET /api/movies"
  echo
  echo "\$ ... | jq '.movies[] | select(.id == ${id})'"
  printf '%s' "${BODY}" | jq --argjson id "${id}" '.movies[] | select(.id == $id)' 2>/dev/null
  if printf '%s' "${BODY}" | jq -e --argjson id "${id}" --arg t "${title}" \
       'any(.movies[]; .id == $id and .title == $t)' >/dev/null 2>&1; then
    ok "the list contains the new movie with the title that was sent"
  else
    bad "the new movie is not in the list"
  fi

  http GET "${API}/api/movies/${id}" "${TOKEN}"
  if [ "${CODE}" = 200 ] && printf '%s' "${BODY}" | jq -e --arg t "${title}" '.title == $t' >/dev/null 2>&1; then
    ok "GET /api/movies/${id} returns the same movie"
  else
    bad "GET /api/movies/${id} did not return the new movie (HTTP ${CODE})"
  fi
}

# billing_counts: "running pending desired" for billing-app.
billing_counts() {
  aws ecs describe-services --cluster "${CLUSTER}" --services "${SVC_BIL}" \
    --query 'services[0].[runningCount,pendingCount,desiredCount]' --output text 2>/dev/null
}

# wait_billing_running N: poll until billing-app runs N tasks with none pending.
wait_billing_running() {
  local want="$1" start="${SECONDS}" running pending
  echo
  echo "\$ aws ecs describe-services --cluster ${CLUSTER} --services ${SVC_BIL} --query 'services[0].[runningCount,pendingCount,desiredCount]' --output text    # every 10 s, up to ${DRILL_WAIT} s"
  pause
  while :; do
    read -r running pending _ <<<"$(billing_counts)"
    note "$((SECONDS - start)) s: running ${running:-?}, pending ${pending:-?}"
    if [ "${running:-}" = "${want}" ] && [ "${pending:-}" = 0 ]; then return 0; fi
    [ $((SECONDS - start)) -ge "${DRILL_WAIT}" ] && return 1
    sleep 10
  done
}

# wait_queue SINCE queued|drained: poll the broker's MessageCount (one point a
# minute, Maximum) from SINCE on, until a point is at least 1 (queued) or the
# newest point is 0 (drained). The metric reaches CloudWatch a minute or more
# after the fact, so this waits instead of reading once.
wait_queue() {
  local since="$1" want="$2" start="${SECONDS}" rows shown peak last
  echo
  echo "\$ aws cloudwatch get-metric-statistics --namespace AWS/AmazonMQ --metric-name MessageCount --dimensions Name=Broker,Value=${NAME_PREFIX}-rabbitmq --start-time ${since} --end-time \$(date -u +%FT%TZ) --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text    # every 20 s, up to ${DRILL_WAIT} s"
  pause
  while :; do
    rows="$(aws cloudwatch get-metric-statistics --namespace AWS/AmazonMQ --metric-name MessageCount \
              --dimensions "Name=Broker,Value=${NAME_PREFIX}-rabbitmq" \
              --start-time "${since}" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
              --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text 2>/dev/null)"
    shown="$(printf '%s\n' "${rows}" | awk 'NF == 2 {printf "%s%s %s", sep, substr($1, 12, 5), $2 + 0; sep = ", "}')"
    note "$((SECONDS - start)) s: messages per minute (UTC): ${shown:-no datapoint yet}"
    peak="$(printf '%s\n' "${rows}" | awk 'NF == 2 && $2 + 0 > m {m = $2 + 0} END {print m + 0}')"
    last="$(printf '%s\n' "${rows}" | awk 'NF == 2 {v = $2 + 0} END {print v}')"
    case "${want}" in
      queued)  [ "${peak}" -ge 1 ] 2>/dev/null && return 0 ;;
      drained) [ "${last}" = 0 ] && return 0 ;;
    esac
    [ $((SECONDS - start)) -ge "${DRILL_WAIT}" ] && return 1
    sleep 20
  done
}

# wait_order USER_ID: poll GET /api/billing/orders until the order is listed.
ORDER=""
wait_order() {
  local uid="$1" start="${SECONDS}" url code
  url="$(tfo billing_orders_url)"
  echo
  echo "\$ curl -sS -H \"Authorization: Bearer \$TOKEN\" ${url} | jq '.orders[] | select(.user_id == ${uid})'    # every 10 s, up to ${DRILL_WAIT} s"
  pause
  while :; do
    code="$(curl -sS -m 20 -H "Authorization: Bearer ${TOKEN}" -o "${TMP}/orders" -w '%{http_code}' "${url}" 2>/dev/null)"
    ORDER="$(jq -c --arg u "${uid}" '[.orders[]? | select((.user_id | tostring) == $u)] | last // empty' "${TMP}/orders" 2>/dev/null)"
    if [ -n "${ORDER}" ]; then
      printf '%s\n' "${ORDER}" | jq .
      return 0
    fi
    note "$((SECONDS - start)) s: HTTP ${code:-000}, the order is not listed yet"
    [ $((SECONDS - start)) -ge "${DRILL_WAIT}" ] && return 1
    sleep 10
  done
}

sec_billing() {
  section "Billing service and queue resilience (B1, B2)" \
    "Q: with the billing service stopped, can a billing request still be sent?" \
    "Q: after the restart, was the queued request processed?"
  local resource="service/${CLUSTER}/${SVC_BIL}" alarm="${NAME_PREFIX}-billing-app-consumers-below-min"
  local started uid body since orders_url suspended_before
  started="$(date -u +%FT%TZ)"
  orders_url="$(tfo billing_orders_url)"

  # --- before: nothing is changed until every precondition holds
  if ! get_token; then
    skip "no Cognito token, so no order can be sent: the drill does not start"
    return
  fi
  if ! describe_services "${SVC_BIL}" || ! jqc '.[0].desired >= 1 and .[0].running == .[0].desired and .[0].rollout == "COMPLETED"'; then
    bad "billing-app is not steady (running tasks differ from desired, or a deployment is rolling): the drill does not start"
    return
  fi
  DRILL_DESIRED="$(jqo '.[0].desired')"
  if ! cap aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "${resource}" \
       --query 'ScalableTargets[0].{min:MinCapacity,max:MaxCapacity,suspended:SuspendedState}' --output json \
     || ! jqc '.min != null and .max != null'; then
    bad "could not read billing-app's scalable target: the drill does not start"
    return
  fi
  DRILL_MIN="$(jqo '.min')"
  DRILL_MAX="$(jqo '.max')"
  DRILL_SUSPENDED="$(jqo '.suspended // {} | "DynamicScalingInSuspended=\(.DynamicScalingInSuspended // false),DynamicScalingOutSuspended=\(.DynamicScalingOutSuspended // false),ScheduledScalingSuspended=\(.ScheduledScalingSuspended // false)"')"
  suspended_before="$(jqo -c "${SUSPENDED_JQ}")"
  note "before the drill: ${DRILL_DESIRED} task(s), min ${DRILL_MIN}, max ${DRILL_MAX}, ${DRILL_SUSPENDED}"
  note "While the consumers are down, ${alarm} fires and emails the alerts topic. That is expected."

  # --- 1. pause auto scaling, so nothing starts a consumer during the outage.
  # Lower the minimum while billing-app still runs its tasks: a register call
  # moves the task count into [min, max] at once, so min 0 must come first.
  echo
  echo "--- 1. pause billing-app's auto scaling (minimum 0, scale-in, scale-out and scheduled scaling suspended)"
  DRILL_ACTIVE=1
  if ! cap aws application-autoscaling register-scalable-target --service-namespace ecs \
       --scalable-dimension ecs:service:DesiredCount --resource-id "${resource}" --min-capacity 0 \
       --suspended-state DynamicScalingInSuspended=true,DynamicScalingOutSuspended=true,ScheduledScalingSuspended=true \
       --output json; then
    bad "could not pause the auto scaling: the drill stops here"
    drill_restore
    return
  fi
  ok "auto scaling paused: minimum 0, every scaling activity suspended"

  # --- 2. stop the only consumer
  echo
  echo "--- 2. stop billing-app (desired count 0)"
  cap aws ecs update-service --cluster "${CLUSTER}" --service "${SVC_BIL}" --desired-count 0 \
    --query 'service.{service:serviceName,desired:desiredCount,running:runningCount}' --output json \
    || bad "aws ecs update-service --desired-count 0 failed"
  if wait_billing_running 0; then
    ok "billing-app runs 0 tasks: no consumer is reading the queue"
  else
    bad "billing-app still runs tasks after ${DRILL_WAIT} s"
  fi
  http GET "${orders_url}" "${TOKEN}"
  if [ "${CODE}" = 503 ]; then
    ok "GET /api/billing/orders answers 503: billing-app is really down"
  else
    warn "GET /api/billing/orders answered ${CODE}, not 503, while billing-app is stopped"
  fi

  # --- 3. B1: the order is accepted with no consumer running
  echo
  echo "--- 3. send an order through API Gateway while billing-app is stopped (B1)"
  uid="$(date +%s)"
  body="$(jq -cn --arg u "${uid}" '{user_id: $u, number_of_items: "2", total_amount: "49.99"}')"
  since="$(date -u +%Y-%m-%dT%H:%M:00Z)"
  http POST "${API}/api/billing" "${TOKEN}" "${body}"
  expect_code 200 "B1: API Gateway accepted the order with no billing-app task running"
  note "the order is marked by user_id ${uid}"

  # --- 4. the order waits in the queue
  echo
  echo "--- 4. the order waits in the queue (broker MessageCount)"
  if wait_queue "${since}" queued; then
    ok "the broker holds the message while no consumer runs"
  else
    warn "MessageCount showed no queued message within ${DRILL_WAIT} s (the metric lags; the order check below still decides B2)"
  fi

  # --- 5. start the consumer again
  echo
  echo "--- 5. start billing-app again (desired count ${DRILL_DESIRED})"
  cap aws ecs update-service --cluster "${CLUSTER}" --service "${SVC_BIL}" --desired-count "${DRILL_DESIRED}" \
    --query 'service.{service:serviceName,desired:desiredCount,running:runningCount}' --output json \
    || bad "aws ecs update-service --desired-count ${DRILL_DESIRED} failed"
  if wait_billing_running "${DRILL_DESIRED}"; then
    ok "billing-app runs ${DRILL_DESIRED} task(s) again"
  else
    bad "billing-app did not reach ${DRILL_DESIRED} running task(s) within ${DRILL_WAIT} s"
  fi

  # --- 6. B2: the queued order was processed
  echo
  echo "--- 6. the queued order was processed (B2)"
  if wait_order "${uid}"; then
    ok "B2: the order sent during the outage is stored in the billing database"
  else
    bad "B2: the order of user_id ${uid} is not listed after ${DRILL_WAIT} s"
  fi
  if cap aws logs tail "/aws/microservices/${NAME_PREFIX}/billing-app" --since 30m --filter-pattern "\"${uid}\""; then
    if printf '%s' "${OUT}" | grep -q "Successfully processed and recorded order"; then
      ok "the billing-app log shows the consumer receiving and recording the order"
    else
      warn "no 'Successfully processed' line for user ${uid} in the billing-app log yet"
    fi
  else
    warn "could not read the billing-app log group"
  fi
  if wait_queue "${since}" drained; then
    ok "MessageCount is back to 0: the queue is drained"
  else
    warn "MessageCount has not shown 0 yet (the metric lags)"
  fi
  cap aws cloudwatch describe-alarm-history --alarm-name "${alarm}" --history-item-type StateUpdate \
    --start-date "${started}" --query 'AlarmHistoryItems[].{time:Timestamp,summary:HistorySummary}' --output table \
    || true
  note "${alarm} goes to ALARM after 3 one-minute periods with fewer than ${DRILL_MIN} running tasks"
  note "(cloudwatch.tf) and back to OK once Container Insights reports the tasks again."

  # --- 7. restore the auto scaling exactly as it was
  echo
  echo "--- 7. restore billing-app's auto scaling (minimum ${DRILL_MIN}, maximum ${DRILL_MAX}, as before)"
  if cap aws application-autoscaling register-scalable-target --service-namespace ecs \
       --scalable-dimension ecs:service:DesiredCount --resource-id "${resource}" \
       --min-capacity "${DRILL_MIN}" --max-capacity "${DRILL_MAX}" --suspended-state "${DRILL_SUSPENDED}" \
       --output json; then
    DRILL_ACTIVE=0
  else
    bad "could not restore the auto scaling (the exit trap tries again)"
  fi
  if cap aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "${resource}" \
       --query 'ScalableTargets[0].{min:MinCapacity,max:MaxCapacity,suspended:SuspendedState}' --output json \
     && jqc --argjson min "${DRILL_MIN}" --argjson max "${DRILL_MAX}" --argjson sus "${suspended_before}" \
          ".min == \$min and .max == \$max and (${SUSPENDED_JQ}) == \$sus"; then
    ok "auto scaling restored: min ${DRILL_MIN}, max ${DRILL_MAX}, ${DRILL_SUSPENDED}"
  else
    bad "billing-app's scalable target does not match the values read before the drill"
  fi
}

sec_load() {
  section "Auto-scaling under load (O1, O2)" \
    "Q: are the auto-scaling policies configured correctly to handle varying workloads?" \
    "Q: does the application stay efficient under different load scenarios?"
  need python3 "runs the load generator"
  show_scaling_config

  local before after token="" result="${TMP}/load.json"
  before="$(desired_counts)"
  note "desired tasks before the load (api-gateway inventory-app): ${before}"
  case "${LOAD_PATH}" in
    /api/*)
      if get_token; then
        token="${TOKEN}"
      else
        skip "no Cognito token for ${LOAD_PATH}; set LOAD_PATH=/health to load the public route"
        return
      fi ;;
  esac

  echo
  echo "\$ python3 - (load generator: GET ${API}${LOAD_PATH}$([ -n "${token}" ] && echo ' with Bearer $TOKEN'), ${LOAD_CONCURRENCY} workers, ${LOAD_DURATION} s)"
  pause
  LOAD_URL="${API}${LOAD_PATH}" LOAD_TOKEN="${token}" LOAD_DURATION="${LOAD_DURATION}" \
  LOAD_CONCURRENCY="${LOAD_CONCURRENCY}" LOAD_RESULT="${result}" python3 -I - <<'PY'
import json, os, threading, time, urllib.error, urllib.request

url = os.environ["LOAD_URL"]
token = os.environ.get("LOAD_TOKEN", "")
duration = int(os.environ["LOAD_DURATION"])
workers = int(os.environ["LOAD_CONCURRENCY"])
headers = {"Authorization": "Bearer " + token} if token else {}
deadline = time.monotonic() + duration
lock = threading.Lock()
latencies, codes = [], {}

def worker():
    while time.monotonic() < deadline:
        request = urllib.request.Request(url, headers=headers)
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                response.read()
                code = str(response.status)
        except urllib.error.HTTPError as err:
            code = str(err.code)
        except Exception as err:  # timeouts, resets: counted, never fatal
            code = type(err).__name__
        elapsed = (time.perf_counter() - t0) * 1000
        with lock:
            latencies.append(elapsed)
            codes[code] = codes.get(code, 0) + 1

threads = [threading.Thread(target=worker, daemon=True) for _ in range(workers)]
start = time.monotonic()
for t in threads:
    t.start()
report = start + 30
while any(t.is_alive() for t in threads):
    time.sleep(0.5)
    if time.monotonic() >= report:
        with lock:
            done = len(latencies)
        print(f"  ... {int(time.monotonic() - start)} s, {done} requests", flush=True)
        report += 30
wall = time.monotonic() - start
latencies.sort()

def pct(p):
    if not latencies:
        return 0.0
    return latencies[min(len(latencies) - 1, max(0, int(round(p / 100 * len(latencies) + 0.5)) - 1))]

summary = {
    "requests": len(latencies),
    "seconds": round(wall, 1),
    "requests_per_second": round(len(latencies) / wall, 1) if wall else 0.0,
    "status_codes": dict(sorted(codes.items())),
    "p50_ms": round(pct(50), 1),
    "p95_ms": round(pct(95), 1),
    "p99_ms": round(pct(99), 1),
}
with open(os.environ["LOAD_RESULT"], "w") as fh:
    json.dump(summary, fh)
print(json.dumps(summary, indent=2))
PY
  if [ ! -s "${result}" ]; then
    bad "the load generator produced no result"
    return
  fi
  local total ok200
  total="$(jq -r '.requests' "${result}")"
  ok200="$(jq -r '.status_codes["200"] // 0' "${result}")"
  if [ "${total}" -gt 0 ] && [ $((ok200 * 100)) -ge $((total * 99)) ]; then
    ok "${ok200} of ${total} requests answered 200 under load ($(jq -r '.requests_per_second' "${result}") req/s, p95 $(jq -r '.p95_ms' "${result}") ms)"
  else
    bad "only ${ok200} of ${total} requests answered 200 under load"
  fi

  show_scaling_after
  after="$(desired_counts)"
  note "desired tasks after the load (api-gateway inventory-app): ${after}"
  if [ "${after%% *}" -gt "${before%% *}" ] 2>/dev/null || [ "${after##* }" -gt "${before##* }" ] 2>/dev/null; then
    ok "the services scaled out under load (${before} -> ${after})"
  else
    warn "no scale-out yet: a task is added once the AlarmHigh alarm above has enough datapoints over 60 % CPU."
    note "Run 'scripts/aws-demo.sh scaling' in a few minutes, or raise LOAD_CONCURRENCY / LOAD_DURATION."
  fi
  note "Scale-in waits for the AlarmLow alarm above, then scale_in_cooldown (300 s) between steps."
}

sec_scaling() {
  section "Auto-scaling (O1): policies, recent activity and CPU"
  show_scaling_config
  show_scaling_after
}

sec_security() {
  section "Security best practices (S1)" \
    "Q: HTTPS, secured API endpoints, database access restricted to the VPC, vulnerability scanning?"

  # --- HTTPS at the edge
  http GET "${API}/health"
  expect_code 200 "API Gateway answers over HTTPS with a valid certificate (curl verifies it)"
  local plain
  echo
  echo "\$ curl -s -m 5 -o /dev/null -w '%{http_code}' http://${API#*://}/health    # plaintext attempt"
  pause
  plain="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${API#*://}/health" 2>/dev/null)"
  case "${plain:-000}" in
    000) note "plaintext http:// gets no answer (HTTP 000): the endpoint listens on HTTPS only" ;;
    *)   note "plaintext http:// answered HTTP ${plain}" ;;
  esac

  # --- the ALB is internal and only the VPC Link may reach it
  local alb sgs
  alb="$(tfo alb_arn)"
  if cap aws elbv2 describe-load-balancers --load-balancer-arns "${alb}" \
       --query 'LoadBalancers[].{name:LoadBalancerName,scheme:Scheme,type:Type,securityGroups:SecurityGroups}' --output json; then
    if jqc 'all(.[]; .scheme == "internal")'; then
      ok "the ALB is internal: no public address, API Gateway is the only public entry"
    else
      bad "the ALB is not internal"
    fi
    sgs="$(jqo '[.[].securityGroups[]] | join(" ")')"
  else
    bad "aws elbv2 describe-load-balancers failed"
  fi
  cap aws elbv2 describe-listeners --load-balancer-arn "${alb}" \
    --query 'Listeners[].{port:Port,protocol:Protocol,sslPolicy:SslPolicy}' --output json || true
  if [ -n "${sgs:-}" ]; then
    # shellcheck disable=SC2086
    if cap aws ec2 describe-security-groups --group-ids ${sgs} \
         --query 'SecurityGroups[].{group:GroupName,ingress:IpPermissions[].{from:FromPort,to:ToPort,sourceGroups:UserIdGroupPairs[].GroupId,cidrs:IpRanges[].CidrIp}}' \
         --output json; then
      if jqc '[.[].ingress[].cidrs[]?] | length == 0'; then
        ok "the ALB security group admits security groups only (the VPC Link), no CIDR range"
      else
        bad "the ALB security group admits a CIDR range"
      fi
    fi
  fi

  # --- secured endpoints
  if [ -n "${API_ID}" ] && cap aws apigatewayv2 get-routes --api-id "${API_ID}" \
       --query 'Items[].{route:RouteKey,auth:AuthorizationType}' --output json; then
    if jqc '[.[] | select(.route | test("/api/"))] | length >= 1 and all(.[]; .auth == "JWT")'; then
      ok "every /api/* route requires a Cognito JWT; only GET /health is public"
    else
      bad "an /api/* route is not protected"
    fi
  fi

  # --- databases: not public, reachable from the app tier only, encrypted
  local dbsgs keys endpoints pg
  if cap aws rds describe-db-instances \
       --filters "Name=db-instance-id,Values=${NAME_PREFIX}-inventory-db,${NAME_PREFIX}-billing-db" \
       --query 'DBInstances[].{id:DBInstanceIdentifier,public:PubliclyAccessible,encrypted:StorageEncrypted,kmsKey:KmsKeyId,securityGroups:VpcSecurityGroups[].VpcSecurityGroupId,parameterGroup:DBParameterGroups[0].DBParameterGroupName,endpoint:Endpoint.Address}' \
       --output json; then
    if jqc 'length == 2 and all(.[]; .public == false)'; then ok "neither database is publicly accessible"; else bad "a database is publicly accessible"; fi
    if jqc 'all(.[]; .encrypted == true and (.kmsKey | length) > 0)'; then ok "both databases are encrypted at rest with a KMS key"; else bad "a database is not encrypted at rest"; fi
    dbsgs="$(jqo '[.[].securityGroups[]] | unique | join(" ")')"
    keys="$(jqo '[.[].kmsKey] | unique | join(" ")')"
    endpoints="$(jqo '[.[].endpoint] | join(" ")')"
    pg="$(jqo '.[0].parameterGroup // empty')"
  else
    bad "aws rds describe-db-instances failed"
  fi
  if [ -n "${dbsgs:-}" ]; then
    # shellcheck disable=SC2086
    if cap aws ec2 describe-security-groups --group-ids ${dbsgs} \
         --query 'SecurityGroups[].{group:GroupName,ingress:IpPermissions[].{from:FromPort,to:ToPort,sourceGroups:UserIdGroupPairs[].GroupId,cidrs:IpRanges[].CidrIp}}' \
         --output json; then
      if jqc '[.[].ingress[].cidrs[]?] | length == 0' && jqc '[.[].ingress[].sourceGroups[]?] | length >= 1'; then
        ok "the database security group admits the app tier's security group only, no CIDR range"
      else
        bad "the database security group admits a CIDR range, or nothing at all"
      fi
    fi
  fi
  if cap aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${NAME_PREFIX}-private-db-rt" \
       --query 'RouteTables[].Routes[].{destination:DestinationCidrBlock,target:GatewayId || NatGatewayId}' --output json; then
    if jqc 'length >= 1 and all(.[]; .destination != "0.0.0.0/0")'; then
      ok "the database subnets have no default route: no path to or from the internet"
    else
      bad "the database route table has a default route"
    fi
  fi
  local host addr
  for host in ${endpoints:-}; do
    addr="$(getent hosts "${host}" 2>/dev/null | awk '{print $1; exit}')"
    echo
    echo "\$ timeout 5 bash -c 'exec 3<>/dev/tcp/${host}/5432'    # from this laptop; ${host} resolves to ${addr:-<no address>}"
    pause
    if ! command -v timeout >/dev/null 2>&1; then
      skip "no timeout command, so the TCP probe of ${host}:5432 is not run"
    elif timeout 5 bash -c "exec 3<>/dev/tcp/${host}/5432" 2>/dev/null; then
      bad "${host}:5432 is reachable from outside the VPC"
    else
      ok "${host}:5432 is not reachable from outside the VPC"
    fi
  done
  if [ -n "${pg:-}" ] && cap aws rds describe-db-parameters --db-parameter-group-name "${pg}" --source user \
       --query 'Parameters[?ParameterName==`rds.force_ssl`].{name:ParameterName,value:ParameterValue}' --output json; then
    if jqc 'any(.[]; .value == "1")'; then ok "rds.force_ssl = 1: the databases refuse plaintext sessions"; else bad "rds.force_ssl is not 1"; fi
  fi
  local key
  for key in ${keys:-}; do
    if cap aws kms get-key-rotation-status --key-id "${key}" --output json; then
      if jqc '.KeyRotationEnabled == true'; then ok "automatic rotation is on for the KMS key"; else bad "KMS key rotation is off"; fi
    fi
  done

  # --- the broker: private, TLS only
  if cap aws mq describe-broker --broker-id "$(tfo amazon_mq_broker_id)" \
       --query '{public:PubliclyAccessible,endpoints:BrokerInstances[0].Endpoints}' --output json; then
    if jqc '.public == false'; then ok "the broker is not publicly accessible"; else bad "the broker is publicly accessible"; fi
    if jqc '(.endpoints | length) >= 1 and all(.endpoints[]; startswith("amqps://") or startswith("https://"))'; then
      ok "the broker exposes TLS endpoints only (amqps, https)"
    else
      bad "the broker exposes a plaintext endpoint"
    fi
  fi

  # --- secrets come from Secrets Manager, never as plain environment values
  local family
  for family in "${NAME_PREFIX}-api-gateway" "${NAME_PREFIX}-inventory-app" "${NAME_PREFIX}-billing-app"; do
    if cap aws ecs describe-task-definition --task-definition "${family}" \
         --query 'taskDefinition.containerDefinitions[].{container:name,secretsFromSecretsManager:secrets[].name,plainEnvironment:environment[].name}' \
         --output json; then
      if jqc '[.[].plainEnvironment[]? | select(test("PASSWORD|SECRET|TOKEN"))] | length == 0'; then
        ok "${family#"${NAME_PREFIX}-"}: credentials arrive as Secrets Manager references, none as plain environment values"
      else
        bad "${family#"${NAME_PREFIX}-"}: a credential is a plain environment value"
      fi
    fi
  done

  # --- vulnerability scanning
  if cap aws inspector2 batch-get-account-status --query 'accounts[].{inspector:state.status,ecr:resourceState.ecr.status}' --output json; then
    if jqc 'any(.[]; .ecr == "ENABLED")'; then ok "Inspector scans the ECR images"; else bad "Inspector ECR scanning is not enabled"; fi
  fi
  local url repo tag critical
  for url in $(printf '%s' "${TF_OUT}" | jq -r '.ecr_repository_urls.value // {} | .[]'); do
    repo="${url#*/}"; tag="${repo##*:}"; repo="${repo%:*}"
    if cap aws ecr describe-image-scan-findings --repository-name "${repo}" --image-id "imageTag=${tag}" \
         --query '{status:imageScanStatus.status,severityCounts:imageScanFindings.findingSeverityCounts}' --output json; then
      critical="$(jqo '.severityCounts.CRITICAL // 0')"
      if [ "${critical}" -gt 0 ] 2>/dev/null; then
        warn "${repo}:${tag} has ${critical} CRITICAL finding(s): rebuild on a patched base image and push again"
      else
        ok "${repo}:${tag} scanned ($(jqo '.status')), no CRITICAL findings"
      fi
    else
      warn "no scan result for ${repo}:${tag} yet"
    fi
  done
}

# ------------------------------------------------------------------------------
# Run the requested sections in order
# ------------------------------------------------------------------------------
for s in "${SECTIONS[@]}"; do
  case "$s" in
    verify)   sec_verify ;;
    lb)       sec_lb ;;
    lb-split) sec_lb_split ;;
    auth)     sec_auth ;;
    movies)   sec_movies ;;
    billing)  sec_billing ;;
    load)     sec_load ;;
    scaling)  sec_scaling ;;
    security) sec_security ;;
  esac
done

echo
echo "=================================================================="
echo " Result: PASS=${PASS} FAIL=${FAIL} WARN=${WARN} SKIP=${SKIP}"
echo "=================================================================="
[ "${FAIL}" -eq 0 ]
