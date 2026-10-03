# Handoff — cloud-design audit hardening

**Date:** 2026-10-03 21:20 UTC
**Repo:** `/home/ertval/code/zone-modules/cloud-design`
**Branch:** `main` -> `origin` (`https://platform.zone01.gr/git/ekaramet/cloud-design.git`)
**Final HEAD:** `b7b761a`. Working tree clean; local `main` is identical to `origin/main`.
**Agents running at handoff:** none. All three work waves finished (see §4).

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

## 1. Read this first — the honesty constraint

`aws` and `terraform` are **not installed** and there are **no AWS credentials** on this box.

Therefore the following are permanently `INVALID` until someone runs them on a real AWS
account, and **no document in this repo may ever present them as passing**:

- `terraform fmt -check`, `terraform validate`, `terraform plan`, `terraform apply`
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

1. **Own `manifests/`** and fix §6.1 — vacuous PDBs and the three missing StatefulSet
   PDBs. Then confirm `test_cloud.sh` FAIL -> 0 FAIL.
2. **Run the Docker verification** for §6.2 and paste the real output: rebuild, then the
   255/256-char title boundary, the DB-down 503 drill, the broker-down 503 drill with a
   hostname-free body, the SIGTERM exit-code drill (use `docker inspect`, not `echo $?` —
   `docker stop` returns the *command's* status), and the full end-to-end billing flow.
   Investigate the 900 KB 500.
3. **Rewrite the docs** against §6.3. Treat it as a rewrite, not a patch — §5.5 changed
   the security model. Remove every transcript you cannot reproduce.
4. **Re-run both suites** and update the counts from the real output (§6.4).
5. **Fresh adversarial review** of `srcs/`, `scripts/`, `manifests/`, docs and
   `terraform/`. The previous mutation agent injected 26 defects and its full detection
   table was truncated out of the transcript — re-run rather than assume coverage. The
   three-state PASS/FAIL/INVALID design and its reachability gating genuinely work (the
   reviewer could not force a false PASS by killing the cluster: 23 checks correctly
   migrated PASS -> INVALID). **Preserve that property.**
6. **Do the Herdr `w6:p2` demonstration** (§6.5).
7. **Answer all 22 `docs/audit.md` questions** and state the verification status of each.

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

