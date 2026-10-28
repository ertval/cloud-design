# Cloud-Design task list

Actionable tasks derived from `progress.md` (2026-10-27). The section numbers in brackets point to the detail and reasoning in `progress.md`. Work the phases in order: later phases depend on earlier ones.

Markers:

- **[YOU]** needs something only you can do: an AWS account, a git command, or an edit inside `docs/`.
- **[AWS]** needs a live AWS deployment and credentials.
- Everything else is a code or documentation change in the repo.

Ground rules for this list: **cheapest option wherever there is a choice**, and **no file in the repository is deleted** (old docs, `docs/HANDOFF.md` and `ecs-tasks/` all stay).

---

## Phase 0: Decisions (decided 2026-10-27, cheapest option each time)

- [x] ~~**D1** TLS on the API Gateway to ALB hop: **no domain, free option.** (3.2)~~
  - Chosen: API Gateway's public endpoint stays HTTPS with its AWS-managed certificate; the hop from the VPC Link to the ALB is plain HTTP inside the VPC, on a listener only the VPC Link security group can reach.
  - Cost avoided: a domain registration (a yearly fee) plus a Route 53 hosted zone ($0.50 per month).
  - Trade-off to state in the README and the role-play: no ACM certificate is in use on this path. The `enable_acm_certificate` toggle stays in Terraform as the documented upgrade (domain + ACM + `tls_config`), and the brief names ACM as an example ("such as"), not a hard rule.
- [x] ~~**D2** Broker mode: **`SINGLE_INSTANCE`.** (3.1)~~
  - Cost: one broker node instead of three for a cluster. By the README's own per-node estimate (~$115 per month per `mq.m7g.medium` node with its EBS volume) that is roughly $115 instead of $345 per month; re-check in the AWS Pricing Calculator.
  - Trade-off to state: the broker runs in one AZ. Amazon MQ replaces a failed instance behind the same endpoint and the durable queue survives on EBS, but during a broker outage `POST /api/billing` returns 503 and the client must retry. The README must stop claiming a Multi-AZ broker.
- [x] ~~**D3** Make the ALB **internal**, with API Gateway as the only public entry. (5.2)~~
  - Cost: free, an internal ALB costs the same as an internet-facing one.
  - Effect: removes the ALB Cognito action (blocker 3.3), the public `:80` and `:443` listeners, the two `0.0.0.0/0` ingress rules and the "any ENI in the VPC can reach :443" residual.
- [x] ~~**D4** Docs: **keep both pairs.** `docs/cloud-design-instructions.md` and `docs/cloud-design-questions.md` become the authoritative brief and rubric; `docs/readme.md` and `docs/audit.md` stay as the earlier versions. `docs/HANDOFF.md` stays too. Nothing is deleted. (6.2)~~
- [x] ~~**D5** Names: **keep the current names** (`api-gateway`, `inventory-database`, `billing-database`, `rabbit-queue`) and document the mapping to the brief's `api-gateway-app`, `inventory-db`, `billing-db`. No renames, no moved files. (6.1)~~

**Further cost levers, not applied** (each one saves money but weakens the Availability answer the audit grades; switch any of them on only if the budget forces it):

- `single_nat_gateway = true`: about $33 per month less, but one AZ failure takes all private egress down.
- RDS `multi_az = false`: roughly halves the database cost, but no standby failover.
- `ecs_use_fargate_spot = true`: up to ~70 % off Fargate, but tasks can be reclaimed with two minutes' warning.

The biggest saving of all costs nothing: deploy shortly before the audit and destroy right after (T59).

---

## Phase 1: Fix the apply and runtime blockers

- [x] ~~**T01** Switch Amazon MQ to `SINGLE_INSTANCE` (D2). A single-instance broker takes exactly one subnet, so set `subnet_ids = [aws_subnet.private_db[0].id]`. Update the cost text and every "Multi-AZ broker" / `ACTIVE_STANDBY_MULTI_AZ` mention. (3.1)~~
  - Files: `terraform/amazon_mq.tf:70-74`, `terraform/terraform.tfvars.example`, `terraform/variables.tf` (cost estimate), `README.md`
  - Done when: `terraform plan` shows the broker as `SINGLE_INSTANCE` and no file still says `ACTIVE_STANDBY_MULTI_AZ`.
  - Done 2026-10-27: `SINGLE_INSTANCE` in one subnet; cost text updated in `variables.tf`, the tfvars example and the README (~$295 steady, ~$335 peak). The budget value itself is left for T20.
- [x] ~~**T02** Rebuild the ALB edge for D1 + D3: `internal = true`, ALB in the private app subnets, an HTTP listener whose rules forward `/api/billing/orders*` to the billing target group and everything else to the api-gateway target group, ALB ingress only from the VPC Link security group, VPC Link egress to that listener port, `integration_uri` pointed at the new listener. Keep the ACM / self-signed resources behind `enable_acm_certificate` as the documented upgrade path, unused by default. (3.2, 5.2)~~
  - Files: `terraform/alb.tf`, `terraform/api_gateway.tf:60-128`, `terraform/security_groups.tf:17-87`, `terraform/outputs.tf` (`alb_https_url`, `app_base_url_via_alb`)
  - Done when: the comments in `alb.tf`, `README.md:898` and `terraform.tfvars.example` all describe the same, real behaviour.
  - Done 2026-10-27, with one change to the plan: the self-signed certificate resources were removed, not kept, because an API Gateway HTTP API cannot skip certificate verification, so they could never be used. The `tls` provider went with them. The ACM path stays behind `enable_acm_certificate` and now also sets `tls_config`. One listener (`aws_lb_listener.main`) replaces the old `http` and `https` pair, and the outputs `alb_https_url` and `app_base_url_via_alb` became `alb_listener`.
- [x] ~~**T03** Remove the ALB `authenticate-cognito` action and the two `source_ip` listener rules (D3 makes them unnecessary); drop the `/oauth2/idpresponse` callback URLs from the Cognito client. The user pool, the hosted UI and the API Gateway JWT authorizer stay. (3.3)~~
  - Files: `terraform/alb.tf:223-360`, `terraform/cognito.tf:120-133`
  - Done 2026-10-27.
- [x] ~~**T04** Add the missing `aws:SecureTransport = false` condition to the `DenyInsecureTransport` statement. (3.4)~~
  - Files: `terraform/storage.tf:143-157`
  - Done when: the policy only denies non-TLS requests.
  - Done 2026-10-27.
- [x] ~~**T05** Make the pushed image tag match what ECS pulls: push `:latest` (or an immutable git-SHA tag passed to Terraform as a variable). (3.5)~~
  - Files: `scripts/build_push.sh:49,167`, optionally `terraform/ecs_services.tf:21` + a new variable
  - Done 2026-10-28: both options. The local tag stays `:local` (docker-compose and `deploy-k3d.sh` use it); `--push` sends each app image as `:latest` and as the git short SHA (`-dirty-<UTC time>` suffix if `srcs/` has uncommitted changes, `IMAGE_TAG` overrides). New variable `image_tag` (default `latest`, validated) feeds `local.ecr_image_urls`. README step 5 no longer re-applies the spent `tfplan`; it pins the SHA or forces a redeploy and waits for `services-stable`.
- [x] ~~**T06** Fix the Cognito demo login: compute `SECRET_HASH` and use the JSON form of `--auth-parameters` (or make the demo client public), and remove `=` and `,` from the demo password alphabet. (3.6)~~
  - Files: `README.md:946-961`, `terraform/cognito.tf:19` (and `:171-190` if the client becomes public)
  - Done 2026-10-28: the demo client keeps its secret. README computes `SECRET_HASH` with `openssl` and builds the JSON `--auth-parameters` with `jq`; `=` dropped from `override_special` (`,` was never in it). Checked locally: AWS CLI 2.38.2 rejects `--secret`, splits a `,` in shorthand into a list (an `=` survives), and the exact README block gets a token from a local mock Cognito that verifies the hash. Also fixed the `-raw`/`-json` note and the demo-client comment in `cognito.tf`.
- [x] ~~**T07** Rewrite the AWS path of `deploy.sh`: ECR first, push, full apply, `aws ecs update-service --force-new-deployment` per service, `aws ecs wait services-stable`, print outputs. No `kubectl` on the AWS path. (3.7)~~
  - Files: `scripts/deploy.sh`
- [x] ~~**T08** Make `destroy.sh --kms` touch only this project's key (by Terraform output or tag), or make the option a no-op that prints the command. The script file stays. (3.8)~~
  - Files: `scripts/destroy.sh:212-245`, `README.md:1322,1333,1511`
- [x] ~~**T09** Re-run `terraform fmt -check -recursive` and `terraform validate` after Phase 1.~~
  - Run on 2026-10-27 after T01-T04: `fmt -check` clean, `validate` passes, and a mocked-provider `terraform test` passes for both `enable_acm_certificate` values. Re-run after T05 if it touches Terraform.
  - Re-run on 2026-10-28 after T05: `fmt -check` clean, `validate` passes, mocked `terraform test` 5 passed (adds `image_tag` default, pinned and invalid cases).

---

## Phase 2: Close the design gaps

- [x] ~~**T10** Raise `api-gateway` to `desired_count = 2` and `min_capacity = 2`; the ALB needs two targets to prove load balancing (V3). Doing the same for `inventory-app` is what makes the "one AZ loss halves capacity" claim true. Each extra 0.25 vCPU / 0.5 GB task costs about $9 per month (the README's ~$37 for 4 tasks). Update the cost table. (5.1)~~
  - Files: `terraform/ecs_services.tf:224,286`, `terraform/autoscaling.tf:28,58`, `terraform/variables.tf`, `README.md`
- [x] ~~**T11** Decide on `billing-app` `desired_count` drift: add `ignore_changes = [desired_count]` or document why not. (5.1)~~
  - Files: `terraform/ecs_services.tf:345-396`
- [x] ~~**T12** Fix the "ALB Target Health" dashboard widget: add the `TargetGroup` dimension, one line per target group. (5.3)~~
  - Files: `terraform/cloudwatch.tf:407-408`
- [x] ~~**T13** Add a CloudWatch Logs Insights widget (errors per service, recent 5xx) to the dashboard. The first three dashboards per account are free. (5.3)~~
  - Files: `terraform/cloudwatch.tf`
- [x] ~~**T14** Add alarms for the queue consumer: `billing-app` running task count below 2, and `MessageCount` staying high. (5.3)~~
  - Files: `terraform/cloudwatch.tf`
- [x] ~~**T15** Enable ALB access logs to the S3 bucket, with a bucket policy statement for ELB log delivery (after T04). Storage cost is pennies at demo volume. (5.3)~~
  - Files: `terraform/alb.tf`, `terraform/storage.tf`, `README.md` (the bucket now has a real use)
- [x] ~~**T16** Optional: make `billing-app` readiness reflect the consumer connection, not only the database. (5.3)~~
  - Files: `srcs/billing-app/app/__init__.py`, `srcs/billing-app/app/consume_queue.py`
- [x] ~~**T17** Add `sslmode=require` to both database URLs (`query={"sslmode": "require"}` in `URL.create`); keep the local stack working (local Postgres has no TLS, so make it an env-driven default such as `DB_SSLMODE`). (5.4)~~
  - Files: `srcs/inventory-app/app/__init__.py:148`, `srcs/billing-app/app/__init__.py:224`, `terraform/ecs_services.tf`, `.env.example`
- [x] ~~**T18** Optional: per-app least-privilege database roles instead of the RDS master user. (5.4)~~
- [ ] **T19** Fix the stale budget text (300 USD / 260 USD) in `terraform/cloudwatch.tf:443-446,489`. (5.3)
- [ ] **T20** Recompute the monthly cost after T01, T02 and T10; update `var.monthly_budget_limit`, the README cost table and the tfvars example together. (5.6)

---

## Phase 3: Demo and audit tooling

- [ ] **T21** Create an AWS demo script (e.g. `scripts/aws-demo.sh` or `make aws-*` targets) with one section per live question: verify (V1-V2), load balancing (V3), 401 and Cognito (S2-S3), POST/GET movies (F1-F2), billing drill (B1-B2), load test (O1-O2), security evidence (S1). (4)
- [ ] **T22** Inside T21, implement the billing drill with the autoscaler handled: set min capacity 0 or suspend scaling, scale `billing-app` to 0, POST through API Gateway, show `MessageCount`, scale back to 2, show the order via `GET /api/billing/orders` and the logs, restore scaling. (4.7)
- [ ] **T23** Add an AWS mode to `scripts/run-audit-checks.sh` and `scripts/step_by_step_audit.py` covering the new questions, keeping PASS / FAIL / INVALID semantics. (6.3)
- [ ] **T24** Point the scripts at `docs/cloud-design-questions.md` as the rubric (D4). `docs/audit.md` is kept, so the existing check in `scripts/test_cloud.sh:53-59` still passes; add a second check for the new file. (6.3)

---

## Phase 4: Deploy and verify on AWS

- [ ] **T25 [YOU]** Create AWS credentials for this project in a dedicated profile (not `code-keeper`) and `export AWS_PROFILE=...`. (4.1)
- [ ] **T26 [YOU]** Enable "Receive CloudWatch billing alerts" in the Billing console; keep the region `us-east-1` for the `EstimatedCharges` alarm. (4.1)
- [ ] **T27 [YOU]** Install the Session Manager plugin (free, for `aws ecs execute-command`). Optional: `kubectl` + `k3d` (free) for the Kubernetes bonus path. (4.1)
- **T28** Skipped: D1 chose the free option, so no domain or hosted zone is needed.
- [ ] **T29 [YOU]** Create `terraform/terraform.tfvars`: `alarm_email`, `allowed_origins`, `enable_acm_certificate = false`; confirm the SNS subscription email after apply. (4.1)
- [ ] **T30 [AWS]** `terraform init`, `plan -out=tfplan`, `apply tfplan`; push images; force new deployments; wait for stable. (4.2)
- [ ] **T31 [AWS]** Fix anything the first apply reveals; check the lower-confidence items: Cloud Map `container_port` with A records, the MQ console port (15671 vs another), RDS 16.9 availability. (5.5)
- [ ] **T32 [AWS]** Run `terraform plan` again and capture **"No changes"**. (4.2)
- [ ] **T33 [AWS]** Capture V1/V2 evidence: `aws ecs describe-services`, `list-tasks`, `describe-tasks`, `elbv2 describe-target-health`, `aws logs tail`, `rds describe-db-instances`, `mq describe-broker`; plus local `docker ps` with the Fargate explanation. (4.3)
- [ ] **T34 [AWS]** Capture V3 evidence: two healthy targets in two AZs and a measured per-target request split (ALB access logs from T15, or CloudWatch `RequestCountPerTarget`). (4.4)
- [ ] **T35 [AWS]** Capture S2/S3 evidence: 401 without a token, 401 with a bad token, 200 with a valid token; `get-authorizers`, `get-routes`, `describe-user-pool`. (4.5)
- [ ] **T36 [AWS]** Capture F1/F2 evidence: POST a movie (with `description`, not `year`) and GET it back through API Gateway. (4.6)
- [ ] **T37 [AWS]** Run the billing drill from T22 and capture B1/B2 evidence. (4.7)
- [ ] **T38 [AWS]** Load test through API Gateway; capture scale-out and scale-in (scaling activities, service events, dashboard), plus the `billing-app` queue-depth scale-out. Record requests per second, p95 and task count. Keep the test short: API Gateway and Fargate bill per request and per second. (4.8)
- [ ] **T39 [AWS]** Capture S1 evidence: the ALB is internal and unreachable from the internet, the API Gateway endpoint is HTTPS, DB not public, DB security group and route table, failed `psql` from outside, Inspector or ECR scan findings, encryption at rest. (4.9)
- [ ] **T40 [AWS]** After a day of running, read the real spend in the Cost Explorer console (free; the Cost Explorer API charges per request). (5.6)

---

## Phase 5: Documentation

- [ ] **T41** Apply the README corrections table: broker mode, 18 vs 19 files, push tag, stale `tfplan` re-apply, VPC Link chain claim, `initiate-auth`, test count, `kubectl get hpa,pdb`, budget 300 vs 450, `--kms` text. (6.1)
  - Already done: broker mode (T01), push tag and stale `tfplan` re-apply (T05), `initiate-auth` (T06).
- [ ] **T42** Add the component-name mapping from D5 to the README component table. (6.1)
- [ ] **T43** Replace the "verified on this machine" tables and audit tallies with numbers re-run on this machine, or reword them. (6.1)
- [ ] **T44** Add a "Verified on AWS" section with the real output from T32 to T40. (6.1)
- [ ] **T45** Add the AWS usage sections: 401 test, billing drill, load test; extend Prerequisites (Session Manager plugin, billing alerts setting). (6.1)
- [ ] **T46** Make `README.md`, the `terraform/*.tf` comments and the `manifests/` comments name `docs/cloud-design-instructions.md` and `docs/cloud-design-questions.md` as authoritative, and mention that `docs/readme.md` and `docs/audit.md` are kept as the earlier versions (D4). (6.1)
- [ ] **T47** Keep every file in `ecs-tasks/`. Refresh the three app task definitions from the real ones exported after deploy (`aws ecs describe-task-definition`; secrets are ARNs, nothing sensitive), and add `ecs-tasks/README.md` stating that `inventory-database`, `billing-database` and `rabbitmq` are reference definitions that are not deployed, because RDS and Amazon MQ replace them. (6.4)
- [x] ~~**T48** Update the architecture diagrams for D2 and D3 (single-instance broker, internal ALB, no ALB Cognito action, API Gateway as the only public entry).~~
  - Done 2026-10-27, together with T01-T03: all three README diagrams.
- [ ] **T49 [YOU]** In `docs/` (read-only for me): nothing to delete (D4). Optionally add one line at the top of `docs/readme.md` and `docs/audit.md` pointing to the new files. (6.2)
- [ ] **T50 [YOU]** In `docs/AUDIT_GUIDE.md`: add answers for V1, F1, F2, B1, B2, S1 (DB restricted to the VPC), S2, S3; update Q5, Q6, Q7, Q9 and the availability pillar after Phases 1 and 2, including the D1 and D2 trade-offs. (6.2)
- [x] ~~**T51** `docs/HANDOFF.md` stays in the repository (D4).~~

---

## Phase 6: Role-play rehearsal

- [ ] **T52** Update the spoken answers for the changed design: single-instance broker, internal ALB, no domain, cost, availability numbers. Be ready to defend each cost choice from Phase 0. (7)
- [ ] **T53** Prepare short answers for the live parts: what each `aws ecs` command proves, no `docker ps` on Fargate, why the queue keeps orders, why `/health` is public. (7)
- [ ] **T54** Prepare the "what would you change" answer with the honest residuals: plaintext inside the VPC (fixed by a domain + ACM), a single-AZ broker (fixed by a cluster), single region, local Terraform state without S3 backend or locking, no CI/CD. (7)
- [ ] **T55 [AWS]** Do one full timed rehearsal of the demo against the live stack. (7)

---

## Phase 7: Bonus (optional, free-tier options only)

- [ ] **T56** FaaS: a small Lambda (within the always-free monthly request allowance), e.g. subscribed to the SNS alert topic and posting to a chat webhook, or a scheduled CloudWatch log export to S3. (8)
- [ ] **T57** CDN: CloudFront in front of API Gateway (within the free monthly allowance at demo traffic). Skip AWS WAF: it is billed per web ACL and per rule. (8)

---

## Phase 8: Commit and teardown

- [ ] **T58 [YOU]** Commit the work yourself (I only run read-only git commands). For example, after reviewing `git status` and `git diff`:
  ```bash
  git add progress.md tasklist.md CHANGELOG.md
  git commit -m "docs: add gap analysis and task list for the cloud-design audit"
  ```
- [ ] **T59 [AWS]** Right after the audit: `terraform destroy`, then run the "verify nothing is left billing" commands (VPCs, RDS, MQ, load balancers, NAT gateways, ECR, S3, KMS). (4.10)
- [ ] **T60** `make down-v` for the local stack if it is no longer needed (removes containers and volumes, not repository files).
