# Handoff — cloud-design audit hardening

> **SUPERSEDED IN PART — read this first.** This document was written at 21:20 UTC
> and described the state at commit `b7b761a`. Five commits and one full
> verification round landed after it. The corrected end state is in
> [§0 — Where things actually ended up](#0--where-things-actually-ended-up) below,
> which supersedes §4, §6.1, §6.2, §6.3, §6.4 and §6.6. §1 (the honesty
> constraint), §5 (the thirteen fixed defects), §7.5 (adversarial review) and §8
> (the do-not list) still stand, with the corrections noted there.

**Date:** 2026-10-03 21:20 UTC · **last updated:** 2026-10-03 22:40 UTC
**Repo:** `/home/ertval/code/zone-modules/cloud-design`
**Branch:** `main` -> `origin` (`https://platform.zone01.gr/git/ekaramet/cloud-design.git`)
**HEAD at handoff:** `b7b761a` · **HEAD now:** `1dcb1f3`, 0 ahead / 0 behind `origin/main`
**Working tree:** 11 modified files, **uncommitted** — see §0.3.
**Agents running now:** none of mine. A **second session in another pane
(`wF`) is concurrently editing this same repo** — see §0.4, because it will
corrupt any tally you take while it writes.

The four commits on top of the previous baseline `ba14ad9`, each produced by a separate
agent that committed its own work:

| Commit | Wave | Subject |
|---|---|---|
| `9c8ddf2` | Terraform | fix(terraform): close the unauthenticated write path and five apply blockers |
| `5f59829` | Docs | docs: add handoff recording the adversarial audit state |
| `7718508` | Application | fix(srcs): report dependency outages as 503 and unblock the queue shutdown |
| `b7b761a` | Scripts | test: replace defeatable greps with real parsers in the audit scripts |

Note the commit order does **not** match the order the waves finished, because the agents
committed independently. Nothing is uncommitted.

---

## 0. Where things actually ended up

*(added 22:40 UTC — this section supersedes §4, §6.1, §6.2, §6.3, §6.4 and §6.6)*

### 0.1 Every remaining open item is closed except one

| §6 item | Status | Evidence |
|---|---|---|
| 6.1 vacuous PDBs + 3 missing StatefulSet PDBs | **CLOSED** | `test_cloud.sh` went 60 PASS / 1 FAIL -> **64 PASS / 0 FAIL / 1 WARN**. `api-gateway` and `inventory-app` moved to `replicas: 2` so `maxUnavailable: 1` actually retains a pod; `billing-app` is a StatefulSet at `replicas: 2`. The three single-replica StatefulSets (both DBs, RabbitMQ) carry **no** PDB on purpose — at `replicas: 1` every budget is vacuous or drain-deadlocking — and each says so next to its `replicas:` line |
| 6.2 app fixes have no live evidence | **CLOSED**, one item stays unknown | All four fixes measured live (below). The 900 KB body **did not reproduce** as a 500 on any variant tried: 921 643 B legal body -> 200 via both the gateway and `:8081`; 1.1 MB -> 413 from nginx, but 1.1 MB direct to `:8081` -> 200 because inventory-app sets no `MAX_CONTENT_LENGTH`. Cause of the original 500 remains **unknown**; do not write a cause into any document |
| 6.3 docs still contain the review's findings | **CLOSED** | Both documents rewritten. Every stale claim is gone: unauthenticated-POST contradiction, `set -euo` claim, PKCE claim, arch-diagram topology, `echo $?` command, JWT audience, cost table, versions, the hardcoded accusation line, `334+335=669`, the "ALB exposes only api-gateway" claim, and the "manifests PDBs are a working control" claim |
| 6.4 audit numbers are stale | **CLOSED** | Re-run, pasted verbatim, never hand-edited. `test_cloud.sh` -> **64 PASS / 0 FAIL / 1 WARN**. `run-audit-checks.sh` -> **PASS=203 FAIL=0 INVALID=1 NOTES=44**, marker `audit-64485-1791054689` |
| 6.5 Herdr `w6:p2` demonstration | **NOT DONE — still outstanding** | See §0.5 |
| 7.7 answer all 22 `docs/audit.md` questions | **CLOSED** | `docs/AUDIT_GUIDE.md` §1 now carries a **Verification status** column (`LIVE` / `STATIC` / `INVALID` / `—`) beside the script verdict, for all 22 |
| 7.5 fresh adversarial review | **DONE** | Two independent read-only reviews (srcs+scripts, and terraform+manifests+docs). Reachability gating **preserved** — see §0.2 |

### 0.2 The two fixes that review found, and the three that were already fine

Fixed and **verified live** in this session:

1. **`srcs/billing-app/app/__init__.py`** — `list_orders()` had no
   `OperationalError` / `InterfaceError` handler, so a billing-DB outage escaped as an
   unhandled 500 with raw Werkzeug HTML while inventory-app correctly returned 503.
   Measured before: `GET /orders` -> 500. Measured after, with `billing-database`
   stopped: **`GET /orders` -> 503** `{"error":"The billing database is currently
   unavailable"}`, `/health` -> 200, `/ready` -> 503.
2. **`srcs/api-gateway-app/app/proxy.py`** — the edge check accepted `user_id: 0`
   (its minimum is `INT32_MIN`) while the consumer rejects 0, so such an order was
   published and then acked-and-discarded as a poison pill: a gateway 200 with a
   silently dropped order. Measured after: `POST /api/billing {"user_id":0,...}` ->
   **400** `{"error":"Field 'user_id' cannot be zero"}`; `user_id: 7` -> 200 unchanged.
3. **`manifests/rabbitmq.yaml`** — the header comments promised the readiness sentinel
   `/tmp/rabbitmq-queue-ready` while the probe tested `/tmp/rabbit-queue-ready`. The
   **probe was right** (`srcs/rabbit-queue/entrypoint.sh:22` is the source of truth);
   the comments were wrong and now match. As written, the probe was never wrong at
   runtime, but the file contradicted itself in three places.

Already correct, verified rather than changed: `app_egress_internal_service` exists
(the dead read path stays fixed), MQ `override_special` has no `,:=`, `mq.m7g.medium`,
RDS `16.9` on both instances, JWT audience is
`concat([main.id], demo[*].id)`, ALB has `authenticate-cognito` + `deny` +
`source_ip` VPC bypass, `billing-app` keeps `desired_count = 2` with **no**
`ignore_changes`, `health_check_grace_period_seconds = 360`, all `*_USER` values are in
`secrets`, the MQ secret has `kms_key_id`, `storage.tf` has zero references from
`ecs_services.tf` (so nothing in the app writes to S3, as documented).

**Reachability gating still works.** `probe_environment()`
(`scripts/run-audit-checks.sh:284-307`) runs before every `step()`, sets
`COMPOSE_STACK_UP` / `CLUSTER_REACHABLE` from live probes only, and unreachable
environments call `invalid()`, never `pass()`. Demonstrated accidentally but
conclusively this session: a full run taken while the compose stack happened to be
down reported **PASS=176 FAIL=0 INVALID=6** — the four live sections migrated to
INVALID instead of silently passing on empty output. Stack up, same script:
**PASS=203 FAIL=0 INVALID=1**.

### 0.3 Uncommitted, on purpose

11 modified files, nothing committed (no commit was requested):

```
README.md  docs/AUDIT_GUIDE.md  docs/HANDOFF.md
manifests/{api-gateway,billing-app,billing-database,inventory-app,inventory-database,rabbitmq}.yaml
scripts/run-audit-checks.sh
srcs/api-gateway-app/app/proxy.py  srcs/billing-app/app/__init__.py
```

### 0.4 A second session is editing this repo right now

Workspace `wF` is running an adversarial-review fan-out against the same working
tree. Two consequences:

- It fixed the S8 replica-count check itself (`scripts/run-audit-checks.sh:902`, the
  container-name regex now tolerates a missing `-N` suffix), which is why the tally
  went from `FAIL=2` to `FAIL=0`.
- **It also rewrote parts of `README.md` and `docs/AUDIT_GUIDE.md` underneath me.**
  I reconciled the tallies, but before trusting any number in those two files, take
  `git diff` and re-run both suites. A full run taken while it was mid-write failed
  with `line 2081: syntax error near unexpected token 'fi'` — the file was being
  rewritten between reads. `bash -n` is clean now.

Also note for whoever reconciles this: the audit numbers are only meaningful with the
compose stack **up**. The S8 log check counts connection errors in the last 15 minutes
of container logs, so **run the outage drills before the audit, not during it.**

### 0.5 The one thing still outstanding: the Herdr demonstration

§6.5 is untouched. Nothing has been run in `w6:p2`. The CLI is available:

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr pane run --help      # inspect the invocation syntax before first use
```

The current workspace is `wF`, not `w6`, so the pane id has to be confirmed rather
than assumed.

> **CORRECTION (added 22:40 UTC).** The first line of this section was wrong and has
> been wrong in every document that repeated it: `aws` and `terraform` **are**
> installed — `aws-cli/2.36.44` and `Terraform v1.9.5`. What is missing is the
> **account**, not the binaries: `aws sts get-caller-identity` returns
> `NoCredentials`. Consequently `terraform fmt -check` and `terraform validate`
> **run for real and pass**, and only the items below are `INVALID`.

**There are no AWS credentials on this box and nothing has ever been applied.**

Therefore the following are permanently `INVALID` until someone runs them on a real AWS
account, and **no document in this repo may ever present them as passing**:

- `terraform plan`, `terraform apply` (and any `aws` call that talks to an account)
- any live inspection of an ALB / RDS / MQ / ECS / API Gateway resource
- proof that API Gateway actually returns `401` for an unauthenticated request
- ACM certificate issuance, Route53 records, Cognito hosted-UI login

Available and genuinely usable: Docker 29.8.1, `kubectl` 1.36.1, k3d 5.9.0
(cluster `cd-audit`, k3s 1.35.5), jq, curl, Python 3.12, OpenSSL.

Mermaid diagrams parse, but SVG rendering is **unverified** (no Chromium).

---

## 2. Architecture (decided, and now implemented in Terraform)

ECS Fargate for three apps — `api-gateway`, `inventory-app`, `billing-app` — plus RDS
PostgreSQL Multi-AZ for both databases, Amazon MQ Active-Standby Multi-AZ for RabbitMQ,
API Gateway HTTP API with a Cognito JWT authorizer, Cloud Map service discovery, and one ALB.

**EKS is gone.** `grep -rn 'aws_eks' terraform/*.tf` is empty. `manifests/` is retained
deliberately as a live-validated k3d/orchestrator-lineage bonus and is **not** the
deployment target.

There are **zero `module` blocks** and **19 `.tf` files**. Any document saying
"18 modules" is wrong — that was the exact error the `docs/` consolidation commit
existed to destroy, and `run-audit-checks.sh` was still printing it on every run.

---

## 3. Provenance — where each piece came from

| Source repo | What was taken |
|---|---|
| `play-with-containers` | Newest app implementations: edge validation, `/ready`, retry handling, `Numeric(12,2)`, graceful shutdown, credential reconciliation |
| `orchestrator` | RabbitMQ startup/readiness, DB init and app-readiness fixes |
| `crud-master` | `scripts/run-audit-checks.sh` — the model for the audit harness |

Canonical app + Dockerfile source is `srcs/<component>/Dockerfile`. The obsolete
top-level `Dockerfiles/` directory was deleted.

---

## 4. Agent wave status — read before trusting anything

> **SUPERSEDED by §0** — the wave table below describes the 21:20 state. Two of the
> three waves were later found to be incomplete: the Terraform wave's fixes all
> verified clean, but the Application wave had a 500-vs-503 hole in `list_orders` and
> an edge/consumer validation mismatch (both fixed, §0.2), and the Scripts wave's
> claims were correct.

| Wave | Owner | Status | Verified? |
|---|---|---|---|
| Terraform | `terraform/**` | **Complete**, self-reported | Manual only — no `terraform` binary |
| Application | `srcs/**` | **Code complete**, killed during verification | `make test-py` = **24 tests OK** (was 18). **No Docker/live evidence produced.** |
| Scripts | `scripts/**` | **Complete and functional** | `test_cloud.sh` = 60 PASS / **1 FAIL** / 3 WARN |

Two of the three agents were **cancelled mid-run**, not timed out cleanly. Their code
landed; their verification and final reports did not. Verified directly after cancellation:

- No process was still writing — source mtimes frozen across a 20 s sample, and no
  python / pytest / docker-compose process alive.
- `bash -n` clean on all six shell scripts; both new `awk` libs parse.
- `python3 -m py_compile` clean on every `srcs` module and test.
- `make test-py` -> 24 tests, **OK**.

**The single `[FAIL]` is a true positive, not a script defect** — see §6.1.

---

## 5. Critical defects found by adversarial review, and now fixed

Each was independently reproduced before being fixed.

1. **The entire read path was dead.** `aws_security_group.app` declared no `egress`
   block, so AWS removed the default allow-all. It had ingress on 8080 but *no egress
   on 8080*. Because SGs are stateful, the ingress rule only covers return traffic — the
   initiating side needs egress. Every `/api/movies` call through API Gateway -> ALB ->
   api-gateway returned **502**. Added `app_egress_internal_service`.
2. **Amazon MQ would have failed to create ~45% of the time.** `override_special`
   contained `=` and `:`; AWS `CreateBroker` rejects `,:=`
   (`Pattern: ^[^,:=]+$`). The value is persisted in state, so a retry reproduced the
   same bad password. Removed both characters, added `min_special = 1`.
3. **Pinned AWS versions that can no longer be created.** `mq.t3.micro` is unavailable
   for new brokers (end of support 2026-10-01) -> `mq.m7g.medium`. RDS
   `engine_version = "16.3"` is a retired minor -> `16.9` (both instances).
   `terraform.tfvars.example` also pinned `mq.t3.micro` and would have re-broken the broker.
4. **Cognito `aud` mismatch broke the documented login.** The authorizer accepted only
   the `main` client id, but the documented flow mints a token via the `demo` client, so
   it returned 401. Now `concat([main.id], demo[*].id)` — the splat yields `[]` at
   `count = 0`, so there is no `[0]` to guard.
5. **The internet-facing ALB had no authenticator** — an unauthenticated
   `POST /api/billing` reached the app and published a real order. Added
   `authenticate_cognito` + `on_unauthenticated_request = "deny"` on the HTTPS listener,
   with `source_ip` rules so the in-VPC API Gateway hop is not 401'd (the ALB reads the
   `aws-cognito-identity-token` **cookie**, not the bearer token, so it cannot consume the
   route-level JWT). The residual trade-off — any ENI inside the VPC can still reach
   :443 — is documented in `alb.tf` rather than hidden.
6. **`app_ingress_self` opened all ports, all protocols** — a lateral-movement path from
   a compromised task to the inventory DB and the broker using its own credentials.
   Narrowed to tcp/8080.
7. **VPC Link SG had no DNS egress** (53/udp, 53/tcp).
8. **Application Auto Scaling fought Terraform** over `desired_count` on `api_gateway` and
   `inventory_app` -> `lifecycle { ignore_changes }`. `billing_app` keeps
   `desired_count = 2` on purpose; a queue consumer must not scale to zero.
9. **Cold-start race:** ECS killed tasks at ~130 s while the app blocks up to 360 s
   waiting for RDS. `health_check_grace_period_seconds = 360`.
10. **`billing-app`'s HTTP surface was unreachable** — no `BILLING_APP_HOST` existed.
    Solved in pure Terraform with a second target group + listener rule; no `srcs/`
    change needed.
11. **DB/broker usernames were plaintext `environment`**, readable by anyone with
    `ecs:DescribeTaskDefinition`. Moved to `secrets` using the already-present,
    previously unused `username` JSON key.
12. **The MQ credential secret had no CMK**, falsifying a README claim and creating a
    latent task-launch trap. Added `kms_key_id`.
13. **`docs/readme.md:143-144` requires "storage services using AWS S3 or similar" — there
    was none.** Added `terraform/storage.tf` (S3, SSE, versioning, full public-access
    block, lifecycle, TLS-only policy), toggleable. **Nothing in the application writes
    to it yet**; it is for build artefacts and log archival. Do not let the docs imply
    otherwise.

Also corrected: a false build-path comment in `ecr.tf` (it pointed at the deleted
`Dockerfiles/`), wrong ECR-scanning pricing, an unsourced ALB certificate-chain claim,
and an inaccurate `try()` explanation.

---

## 6. Open items

> **MOSTLY SUPERSEDED by §0.1**, which gives the status and evidence for each item.
> The text below is kept as the original statement of what was wrong, because §0
> refers back to it.

### 6.1 The one failing check — a real defect in `manifests/`

```
[FAIL] 3 disruption-budget finding(s) are vacuous: a PDB that permits evicting
       every pod still gets counted as a control
       api-gateway (maxUnavailable=1 >= replicas=1)
       billing-app    (maxUnavailable=1 >= replicas=1)
       inventory-app  (maxUnavailable=1 >= replicas=1)
[WARN] StatefulSet(s) with no PodDisruptionBudget:
       billing-database inventory-database rabbitmq
```

All six workloads are `replicas: 1` and every PDB is `maxUnavailable: 1`, which permits
evicting the only pod. The three StatefulSets (both DBs + RabbitMQ) have **no PDB at
all**. This is exactly what the new check was written to catch. `manifests/` is
currently **unowned** — fix it here.

### 6.2 Application fixes have no live evidence

All four reproduced app bugs are fixed and unit-tested, but **nobody has run the Docker
verification**:

- 256-char `title` -> **400** (was an unhandled 500 leaking raw Flask HTML). 255 still 200.
- Dependency outage -> **503** (was 500). `/health` stays DB-independent and 200;
  `/ready` stays DB-aware and 503.
- Internal hostnames no longer leak into client-facing bodies; the detail moved to the
  server log.
- SIGTERM race fixed in `consume_queue.py` — the watcher now exists before the blocking
  `start_consuming()` call. Exit code should be **0**, not 137.
  `srcs/billing-app/tests/test_shutdown.py` covers it.

**Still unverified:** the 900 KB legal body returning **500** through nginx (413 for
>1 MiB is expected; 900 KB is under both nginx `client_max_body_size` and Flask
`MAX_CONTENT_LENGTH`, so the 500 is a bug — cause not yet identified). Also,
`_sanitise_subpath()` path traversal is currently blocked by nginx, so the app's own
defence-in-depth is unproven in the running stack.

### 6.3 The docs still contain the defects the review found — the docs wave never ran

Every item below is a **known-false claim still present in `README.md` /
`docs/AUDIT_GUIDE.md`**:

- Self-contradictory security disclosure: the guide says no write path is exposed while
  also documenting an unauthenticated `POST /api/billing` through the ALB. §5.5 changed
  this materially — the docs must be rewritten, not patched.
- **Two critical fabrications** and **six false "Real output" blocks** — transcripts
  presented as real that were never produced by the commands shown.
- False claim of "uniform shell discipline: `set -euo pipefail`, no `|| true` anywhere in
  a deploy path". In fact **no** script uses `-e`, and `|| true` appears in `deploy.sh`
  (x4), `deploy-k3d.sh`, `build_push.sh`, `destroy.sh`, `test_cloud.sh` (x4) and
  `run-audit-checks.sh` (x5).
- False claim of a "public PKCE client".
- Wrong README architecture diagram: six NAT edges, KMS / Secrets Manager drawn inside
  the VPC, Route53 drawn outside the VPC, and a User -> ALB -> VPC Link hop that does not
  exist.
- A "verify the exit code" command that cannot fail.
- JWT walkthrough with the wrong audience.
- Stale cost table and budget: MQ ~$79 -> ~$230, total ~$260 -> ~$410,
  `monthly_budget_limit` 300 -> **450**.
- Stale versions: `mq.t3.micro`, RDS `16.3`.
- `run-audit-checks.sh` printed a false accusation against `docs/AUDIT_GUIDE.md` on every
  run, citing a hardcoded line number and repeating the "18 modules" error. **Verify
  whether the scripts agent removed this** before trusting a run.
- Measured numbers in both documents (pod counts, request splits) need re-derivation.
  The guide contained `334 + 335 = 669 != 200` requests.
- Any statement that the ALB exposes only `api-gateway` — `billing-app` now has a route.
- Any statement that `manifests/` PDBs are a working control — see §6.1.

### 6.4 Audit numbers are stale

`test_cloud.sh` last measured **60 PASS / 1 FAIL / 3 WARN**.
`run-audit-checks.sh` last measured **173 / 0 / 4 / 39**, but that was *before* this
whole fix round. Both suites gained checks; both numbers in the docs are wrong until
re-run. Note the counts in the docs must never be hand-edited to match prose — re-run
and paste.

### 6.5 The Herdr requirement is entirely outstanding

The user requires every final audit command and its real output to be shown in the
**next pane, `w6:p2`** (workspace `w6`). **Nothing has been run there.** This is a hard
requirement, not a nice-to-have.

```
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr pane run --help      # inspect the invocation syntax before first use
```

### 6.6 Commit state — everything is committed, nothing is at risk

An earlier draft of this handoff claimed the work was uncommitted. That was wrong, and
worth recording why it went wrong: **a `git commit` writes no working-tree file**, so
checking file mtimes to decide whether an agent was still active gave a false "all quiet".
`ps` for python/pytest/docker-compose also came back empty, because the agent was
committing, not testing. The scripts agent was alive and committing at that moment.

The reliable checks are `git log`, `git status`, and `git rev-list --left-right --count
origin/main...HEAD`. Use those, not mtimes.

Current state: working tree clean, `HEAD` == `origin/main` == `b7b761a`, 0 ahead / 0
behind. The four wave commits plus the baseline are all on the remote.

---

## 7. Next actions, in order

*(status as of 22:40 UTC; see §0 for the evidence)*

1. ~~**Own `manifests/`** and fix §6.1~~ — **DONE.** 3 effective PDBs, 0 FAIL.
2. ~~**Run the Docker verification**~~ — **DONE** for the four fixed defects; the
   900 KB 500 **did not reproduce** and stays an open unknown (§0.1).
3. ~~**Rewrite the docs** against §6.3~~ — **DONE**, as a rewrite.
4. ~~**Re-run both suites** and update the counts from real output~~ — **DONE**:
   64/0/1 and 203/0/1/44.
5. ~~**Fresh adversarial review**~~ — **DONE**, two scopes, read-only; reachability
   gating re-confirmed (§0.2).
6. **Do the Herdr `w6:p2` demonstration** (§6.5) — **STILL OUTSTANDING.** This is
   the only item from the original list that nobody has touched.
7. ~~**Answer all 22 `docs/audit.md` questions**~~ — **DONE**, with a verification
   status per question in `docs/AUDIT_GUIDE.md` §1.
8. **NEW — reconcile the concurrent session.** `wF` is still editing `README.md` and
   `docs/AUDIT_GUIDE.md` (§0.4). Re-run both suites and re-check the tallies after it
   stops, then commit all 12 files together.

## 8. Do not

- Do not present any AWS or Terraform result as passing. There is no `terraform` and no
  `aws` on this box.
- Do not hand-edit audit counts. Re-run and paste.
- Do not blanket-add `set -e` to `run-audit-checks.sh` — its non-aborting design is
  deliberate and is the whole point (show the examiner every rubric item).
- Do not let the docs claim the S3 bucket is used by the application. Nothing writes to it.
- Do not remove the `INVALID` state to make a report look better. The remaining 4 INVALIDs
  and 3 WARNs are honest and correct.
- Do not add an `aws_kms_key_policy` for `aws_kms_key.rds` — the AWS default key policy
  already delegates to IAM and the one grant that matters exists. A hand-written policy
  would be a regression risk for no gain.
- Do not scale `billing-app` to zero via autoscaling. It is a queue consumer.

