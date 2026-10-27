#!/usr/bin/env python3
"""Drive the cloud-design docs/audit.md walkthrough through a Herdr pane.

Why a driver instead of a plain script: during the audit the examiner wants to
see each command typed and its real output. This sends the *literal* rubric
commands to a terminal pane (one per step, with a header), waits for the shell
prompt to come back, and leaves the whole transcript on screen.

Steps are grouped into SECTIONS so `--only` can select a rubric area rather than
a single command, and so the driver composes with scripts/run-audit-checks.sh:
the same section numbers address the same audit.md questions in both tools.

PANE DISCOVERY -- there is deliberately NO hardcoded pane id.
    herdr pane list
prints the available panes as `window:pane` (e.g. `w3:p1`). Pick one and pass it
with --pane. If --pane is omitted and exactly one pane exists, it is used; if
several exist and none was given, this script refuses to guess and prints the
command to run.

Usage:
    scripts/step_by_step_audit.py --list
    scripts/step_by_step_audit.py --dry-run
    scripts/step_by_step_audit.py --only 9
    scripts/step_by_step_audit.py --section 10 --end 12
    scripts/step_by_step_audit.py --pane w3:p1

Exit codes: 0 ok, 2 bad usage / no pane, 3 herdr not installed.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# The walkthrough. (section, title, command, mutates_state)
# The commands are the ones docs/audit.md asks the auditee to demonstrate.
# --------------------------------------------------------------------------
STEPS = [
    # --- section 1: repo content (audit.md:11) -----------------------------
    (1, "Repo content: required files, real counts (audit.md:11)",
     "ls -1 README.md Makefile docker-compose.yml .env.example && "
     "ls -d srcs manifests ecs-tasks scripts docs terraform && "
     "echo \"tf=$(ls -1 terraform/*.tf | wc -l)  manifests=$(ls -1 manifests/*.yaml | wc -l)  "
     "ecs=$(ls -1 ecs-tasks/*.json | wc -l)  dockerfiles=$(ls -1 srcs/*/Dockerfile | wc -l)\"", False),
    (1, "audit.md used to live at the repo root; it is now docs/audit.md (audit.md:11)",
     "ls -1 docs/ && grep -c '^######' docs/audit.md | xargs echo 'audit.md questions:'", False),

    # --- section 2: the two-stack reality ----------------------------------
    (2, "Tooling reality: what is and is not available (audit.md:62,70,76)",
     "for t in docker kubectl k3d aws terraform jq curl; do "
     "printf '%-10s %s\\n' \"$t\" \"$(command -v $t 2>/dev/null || echo NOT-INSTALLED)\"; done", False),

    # --- section 4: local stack, live (audit.md:64,66,90) ------------------
    (4, "docker ps: every microservice running and healthy (audit.md:64)",
     "docker compose ps", False),
    (4, "Container health + non-root execution (audit.md:64,94)",
     "for c in $(docker compose ps -q); do docker inspect -f '{{.Name}} {{.State.Status}} "
     "health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} "
     "user={{.Config.User}}' $c; done", False),
    (4, "Live health endpoints through the load balancer (audit.md:64)",
     "curl -s -i http://localhost:3000/health && echo && "
     "curl -s -i http://localhost:8081/ready && echo && curl -s -i http://localhost:8082/ready", False),
    (4, "End-to-end: gateway -> inventory-app -> inventory-database (audit.md:64)",
     "curl -s -i http://localhost:3000/api/movies/", False),

    # --- section 5: load balancing, live (audit.md:66) ---------------------
    (5, "Load balancing PROOF: 20 requests, then the per-replica upstream counts (audit.md:66)",
     "for i in $(seq 1 20); do curl -s -o /dev/null http://localhost:3000/health; done; "
     "docker compose logs --since=1m gateway-lb | grep -oE 'upstream=[0-9.]+:[0-9]+' | sort | uniq -c", False),
    (5, "Static counterpart: the ALB target group the demo stands in for (audit.md:66)",
     "grep -nE '^resource \"aws_lb' terraform/alb.tf && "
     "grep -A 12 'aws_lb_target_group' terraform/alb.tf | grep -E 'port|health_check|path|target_type'", False),

    # --- section 6: secure communication (audit.md:68,94) ------------------
    (6, "Broker refuses anonymous management access (audit.md:68)",
     "curl -s -o /dev/null -w 'no-credentials /api/overview -> HTTP %{http_code}\\n' "
     "http://localhost:15672/api/overview", False),
    (6, "Queue round-trip: publish an order, watch the consumer drain it (audit.md:68,90)",
     "curl -s -X POST http://localhost:3000/api/billing/ -H 'Content-Type: application/json' "
     "-d '{\"user_id\": \"424242\", \"number_of_items\": \"7\", \"total_amount\": \"99\"}'; echo; "
     "docker exec cloud-design-rabbit-queue rabbitmqctl list_queues name messages 2>/dev/null | tail -3", True),
    (6, "The order actually landed in PostgreSQL (audit.md:68)",
     "docker exec cloud-design-billing-database psql -U postgres -d billing_db "
     "-c \"SELECT user_id, number_of_items, total_amount FROM orders "
     "WHERE user_id='424242' ORDER BY id DESC LIMIT 3;\"", False),
    (6, "Static: Cognito authorizer attached to every non-health API Gateway route (audit.md:68)",
     "grep -nE '^resource \"aws_apigatewayv2_route\"|authorizer_id' terraform/api_gateway.tf", False),
    (6, "Static: KMS at rest, Secrets Manager, private data tier (audit.md:68,94)",
     "grep -c kms_key_id terraform/rds.tf | xargs echo 'rds kms_key_id refs:' && "
     "grep -rhc '^resource \"aws_secretsmanager_secret\"' terraform/*.tf | paste -sd+ | bc | xargs echo 'secrets:' && "
     "grep -n 'publicly_accessible' terraform/rds.tf terraform/amazon_mq.tf", False),

    # --- section 7: the k3d cluster, live (audit.md:64,66,80,88) -----------
    (7, "kubectl: the full stack in namespace cloud-design (audit.md:64)",
     "kubectl get pods -n cloud-design -o wide", False),
    (7, "Services, ingress and network isolation (audit.md:64,68)",
     "kubectl get svc,ingress -n cloud-design && echo && "
     "kubectl get networkpolicy -n cloud-design", False),
    (7, "Auto-scaling actually live, with real metrics (audit.md:88)",
     "kubectl get hpa -n cloud-design && echo && kubectl top pods -n cloud-design 2>&1 | head -8", False),

    # --- section 8: orchestration correctness (audit.md:80) ----------------
    (8, "Why 'kubectl apply -f manifests/' is BROKEN and '-k' is required (audit.md:80)",
     "kubectl apply -f manifests/ --dry-run=client 2>&1 | tail -4; echo \"exit=$?\"", False),
    (8, "The supported path: kustomize build, then a server-side dry run (audit.md:80)",
     "kubectl kustomize manifests/ | grep -c '^kind:' | xargs echo 'objects:' && "
     "kubectl apply --dry-run=server -k manifests/ 2>&1 | tail -6", False),
    (8, "ECS task definitions: valid JSON, families and port mappings (audit.md:80)",
     "for j in ecs-tasks/*.json; do echo -n \"$j: \"; jq -c '{family, net:.networkMode, "
     "ports:[.containerDefinitions[].portMappings[].containerPort]}' \"$j\"; done", False),

    # --- section 9: Dockerfile optimisation (audit.md:78) ------------------
    (9, "Real Dockerfile analysis: base image, stages, USER, COPY --chmod (audit.md:78)",
     "for f in srcs/*/Dockerfile; do echo \"== $f\"; grep -nE '^FROM|^USER|^EXPOSE|^COPY .*--chmod' \"$f\"; done", False),
    (9, "Real measured image sizes (audit.md:78)",
     "docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep '^cloud-design/' | sort", False),

    # --- section 10: Terraform, statically (audit.md:72,74) ----------------
    (10, "Terraform: module inventory and resource density (audit.md:72)",
     "ls -1 terraform/*.tf | wc -l | xargs echo 'tf files:' && "
     "grep -h '^resource ' terraform/*.tf | wc -l | xargs echo 'resources:' && "
     "for f in terraform/*.tf; do printf '%-24s %s\\n' \"$(basename $f)\" "
     "\"$(grep -c '^resource ' $f)\"; done", False),
    (10, "Terraform: variables declared vs actually referenced (audit.md:72)",
     "echo \"declared: $(grep -c '^variable ' terraform/variables.tf)\"; "
     "echo \"referenced: $(grep -rhoE 'var\\.[a-z0-9_]+' terraform/*.tf | sort -u | wc -l)\"", False),
    (10, "terraform validate/fmt are INVALID here: the binary is not installed (audit.md:72)",
     "command -v terraform >/dev/null 2>&1 && terraform -chdir=terraform validate "
     "|| echo 'INVALID (tool not installed): terraform fmt/validate/plan cannot be run in this environment'", False),
    (10, "Cost controls: budget, right-sizing, NAT toggle (audit.md:54)",
     "grep -nE 'monthly_budget_limit|db.t4g.micro|mq.t3.micro|single_nat_gateway|skip_final_snapshot' "
     "terraform/variables.tf terraform/rds.tf terraform/vpc.tf | grep -v description", False),

    # --- section 11: monitoring and security (audit.md:84,94) --------------
    (11, "Monitoring: dashboard widgets, log groups, alarm count, SNS (audit.md:84)",
     "grep -c 'type   = \"metric\"' terraform/cloudwatch.tf | xargs echo 'dashboard widgets:' && "
     "grep -c '^resource \"aws_cloudwatch_log_group\"' terraform/cloudwatch.tf | xargs echo 'log groups:' && "
     "grep -c '^resource \"aws_cloudwatch_metric_alarm\"' terraform/cloudwatch.tf | xargs echo 'metric alarms:' && "
     "grep -cE '^resource \"aws_sns_topic(_policy)?\"' terraform/cloudwatch.tf | xargs echo 'sns topic+policy:'", False),
    (11, "Security: internal ALB behind HTTPS API Gateway, Inspector v2, ECR scan-on-push, no hardcoded creds (audit.md:94)",
     "grep -nE 'internal *=|protocol *=|ssl_policy|server_name_to_verify' terraform/alb.tf terraform/api_gateway.tf | head -8; echo; "
     "grep -rn 'aws_inspector2\\|scan_on_push' terraform/*.tf; echo; "
     "grep -rnE 'getenv\\([^)]*, *\"[^\"]*pass' srcs/ || echo 'no hardcoded password defaults in srcs/'", False),
    (11, "No credentials committed: secrets.yaml is placeholders only (audit.md:94)",
     "grep -E '^[[:space:]]+[A-Z0-9_]+:[[:space:]]*\"' manifests/secrets.yaml", False),

    # --- section 12: load, live (audit.md:90) ------------------------------
    (12, "Throughput and latency under real concurrent load (audit.md:90)",
     "S=$(date +%s.%N); seq 1 200 | xargs -P 20 -I{} curl -s -m 10 -o /dev/null "
     "-w '%{http_code} %{time_total}\\n' http://localhost:3000/health > /tmp/l.txt; "
     "E=$(date +%s.%N); echo \"elapsed: $(echo \"$E - $S\"|bc)s\"; "
     "echo \"codes:\"; awk '{print $1}' /tmp/l.txt | sort | uniq -c; "
     "echo \"latency:\"; sort -k2 -g /tmp/l.txt | awk '{a[NR]=$2;s+=$2} "
     "END{printf \"min=%.1fms avg=%.1fms p95=%.1fms max=%.1fms\\n\", a[1]*1000, (s/NR)*1000, "
     "a[int(NR*0.95)+1]*1000, a[NR]*1000}'", False),
    (12, "Load-balancer distribution observed under that load (audit.md:66,90)",
     "docker compose logs --since=2m gateway-lb | grep -oE 'upstream=[0-9.]+:[0-9]+' | sort | uniq -c", False),

    # --- section 13: the full automated suite (composes with run-audit-checks.sh)
    (13, "THE FULL AUTOMATED SUITE: every rubric item with a PASS/FAIL/INVALID verdict",
     "./scripts/run-audit-checks.sh --no-color", False),
    (13, "The static-only companion suite",
     "./scripts/test_cloud.sh", False),
]

SECTIONS = sorted({s for s, _, _, _ in STEPS})


# --------------------------------------------------------------------------
# herdr plumbing
# --------------------------------------------------------------------------
def herdr(*args):
    return subprocess.run(["herdr", *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)


def discover_panes():
    """Return [(window, pane), ...] from `herdr pane list`. Never guesses."""
    if shutil.which("herdr") is None:
        return None
    r = herdr("pane", "list")
    if r.returncode != 0:
        return []
    panes = []
    for m in re.finditer(r"\bw(\d+)\s*:\s*p(\d+)\b", r.stdout):
        panes.append((m.group(1), m.group(2)))
    # Preserve order, drop duplicates.
    seen, out = set(), []
    for w, p in panes:
        if (w, p) not in seen:
            seen.add((w, p))
            out.append((w, p))
    return out


def resolve_pane(explicit):
    if explicit:
        return explicit
    panes = discover_panes()
    if panes is None:
        print("herdr is not installed (or not on PATH).", file=sys.stderr)
        print("Install it, or drop --dry-run and run the steps by hand.", file=sys.stderr)
        sys.exit(3)
    if len(panes) == 1:
        return f"w{panes[0][0]}:p{panes[0][1]}"
    print("More than one Herdr pane is available, so this script will not guess one.", file=sys.stderr)
    print("Run this and pass the pane you want with --pane:", file=sys.stderr)
    print("    herdr pane list", file=sys.stderr)
    print("Panes found: " + ", ".join(f"w{w}:p{p}" for w, p in panes), file=sys.stderr)
    sys.exit(2)


def in_pane(pane, cmd):
    r = herdr("pane", "run", pane, cmd)
    if r.returncode != 0:
        print(f"herdr pane run failed: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)


def read_pane(pane, lines=6):
    r = herdr("pane", "read", pane, "--source", "recent-unwrapped", "--lines", str(lines))
    if r.returncode != 0:
        return ""
    try:
        return json.loads(r.stdout).get("result", {}).get("text", r.stdout)
    except json.JSONDecodeError:
        return r.stdout


def prompt_idle(pane, quiet_for=2.0, timeout=600):
    """Wait until the pane's last lines stop changing (the command finished)."""
    deadline = time.time() + timeout
    last, stable_since = None, time.time()
    while time.time() < deadline:
        current = read_pane(pane, 4)
        if current and current == last:
            if time.time() - stable_since >= quiet_for:
                return True
        else:
            last, stable_since = current, time.time()
        time.sleep(0.5)
    return False


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Drive the docs/audit.md walkthrough through a Herdr pane.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Find your pane with:  herdr pane list")
    ap.add_argument("--pane", default=None,
                    help="target pane as wN:pM. Omit to use the only pane; "
                         "if several exist this refuses to guess and prints the "
                         "command to find them.")
    ap.add_argument("--delay", type=float, default=2.0,
                    help="extra seconds to wait after each step settles (default 2)")
    ap.add_argument("--only", type=int, action="append", metavar="N",
                    help="run only this step number; repeatable")
    ap.add_argument("--section", type=int, action="append", metavar="N",
                    help="run only this section (same numbering as "
                         "run-audit-checks.sh); repeatable")
    ap.add_argument("--start", type=int, default=1, help="first step to run (1-based)")
    ap.add_argument("--end", type=int, default=len(STEPS), help="last step to run (1-based)")
    ap.add_argument("--list", action="store_true", help="list every step and exit")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and exit without touching any pane")
    args = ap.parse_args()

    if args.list:
        print(f"{'#':>3}  {'sec':>3}  {'mutates':<8}  title")
        for i, (sec, title, _, mut) in enumerate(STEPS, 1):
            print(f"{i:>3}  {sec:>3}  {'[STATE]' if mut else '-':<8}  {title}")
        print()
        print("Sections: " + ", ".join(str(s) for s in SECTIONS))
        print("These are the SAME section numbers used by scripts/run-audit-checks.sh.")
        print("Mutating steps are tagged [STATE] and write to PostgreSQL or publish to RabbitMQ.")
        return 0

    wanted = []
    for i, (sec, title, cmd, mut) in enumerate(STEPS, 1):
        if not (args.start <= i <= args.end):
            continue
        if args.only and i not in args.only:
            continue
        if args.section and sec not in args.section:
            continue
        wanted.append((i, sec, title, cmd, mut))

    if not wanted:
        print("No steps matched the selection.", file=sys.stderr)
        print("Try --list to see what exists.", file=sys.stderr)
        return 2

    print(f"Plan: {len(wanted)} step(s) of {len(STEPS)}.")
    if args.dry_run:
        print("DRY RUN -- no pane is touched, nothing is executed.\n")
        for i, sec, title, cmd, mut in wanted:
            tag = " [mutates state]" if mut else ""
            print(f"[{i:>3}] section {sec}{tag}\n        {title}")
            print(f"        $ {cmd}\n")
        if shutil.which("herdr") is None:
            print("herdr is not installed; --dry-run still worked, real runs would need it.")
        else:
            panes = discover_panes()
            if panes is None:
                print("herdr present but 'herdr pane list' failed.")
            elif len(panes) == 1:
                print(f"herdr pane list -> 1 pane available: w{panes[0][0]}:p{panes[0][1]}")
            else:
                print("herdr pane list -> panes available: "
                      + ", ".join(f"w{w}:p{p}" for w, p in panes))
                print("Pass one with --pane wN:pM")
        return 0

    pane = resolve_pane(args.pane)
    print(f"Target pane: {pane}")

    in_pane(pane, "clear")
    time.sleep(0.5)
    in_pane(pane, r"echo -e '\033[1;36m=== cloud-design docs/audit.md STEP-BY-STEP WALKTHROUGH ===\033[0m'")
    in_pane(pane, f"cd {REPO}")
    time.sleep(0.8)

    for i, sec, title, cmd, mut in wanted:
        tag = r" \033[1;31m[mutates state]\033[0m" if mut else ""
        print(f"[{i}/{len(STEPS)}] section {sec}: {title}{' [mutates state]' if mut else ''}")
        in_pane(pane, f"echo -e '\\n\\033[1;33m>>> Step {i}/{len(STEPS)} (section {sec}): {title}{tag}\\033[0m'")
        time.sleep(0.4)
        in_pane(pane, cmd)
        slow = ("run-audit-checks" in cmd) or ("test_cloud" in cmd) or ("xargs -P" in cmd)
        prompt_idle(pane, timeout=900 if slow else 300)
        time.sleep(args.delay)

    in_pane(pane, r"echo -e '\n\033[1;32m=== END OF docs/audit.md WALKTHROUGH ===\033[0m'")
    print("Done. The full transcript is in the pane.")
    return 0


if __name__ == "__main__":
    sys.exit(main())