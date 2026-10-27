# Cloud-Design task list

Actionable tasks derived from `progress.md` (2026-10-27). The section numbers in brackets point to the detail and reasoning in `progress.md`. Work the phases in order: later phases depend on earlier ones.

Markers:

- **[YOU]** needs something only you can do: an AWS account, a domain, a decision, a git command, or an edit inside `docs/`.
- **[AWS]** needs a live AWS deployment and credentials.
- Everything else is a code or documentation change in the repo.

---

## Phase 0: Decisions (do these first, they change the fixes)

- [ ] **D1 [YOU]** Choose the TLS option for the API Gateway to ALB hop: **A** = own or buy a Route 53 domain and use ACM + HTTPS with `tls_config`; **B** = no domain, HTTP listener reachable only from the VPC Link. (3.2)
- [ ] **D2 [YOU]** Choose the broker mode: `CLUSTER_MULTI_AZ` (recommended, keeps the Multi-AZ claim) or `SINGLE_INSTANCE` (cheaper, README must drop the Multi-AZ claim). (3.1)
- [ ] **D3 [YOU]** Decide whether to make the ALB internal so API Gateway is the only public entry (recommended). (5.2)
- [ ] **D4 [YOU]** Decide whether `docs/cloud-design-instructions.md` and `docs/cloud-design-questions.md` replace `docs/readme.md` and `docs/audit.md`, or both pairs stay with one marked authoritative. (6.2)
- [ ] **D5 [YOU]** Confirm the component naming policy: keep `api-gateway`, `inventory-database`, `billing-database` and document the mapping to the brief's `api-gateway-app`, `inventory-db`, `billing-db`, or rename. (6.1)

---

## Phase 1: Fix the apply and runtime blockers

- [ ] **T01** Set the Amazon MQ deployment mode from D2. If `CLUSTER_MULTI_AZ` and the API rejects two subnets, add a third private DB subnet in a third AZ. (3.1)
  - Files: `terraform/amazon_mq.tf:71` and its comment at `:70`, `terraform/terraform.tfvars.example`, `terraform/variables.tf` (cost text)
  - Done when: `terraform plan` shows the broker with the chosen mode and no other file still says `ACTIVE_STANDBY_MULTI_AZ`.
- [ ] **T02** Fix the API Gateway to ALB integration according to D1. Option A: add `tls_config { server_name_to_verify = var.alb_domain_name }` and require `enable_acm_certificate = true`. Option B: add a VPC-Link-only HTTP listener and point `integration_uri` at it. (3.2)
  - Files: `terraform/api_gateway.tf:119-128`, `terraform/alb.tf`, `terraform/security_groups.tf`
  - Done when: the comments in `alb.tf:21-24`, `README.md:898` and `terraform.tfvars.example` all describe the same, real behaviour.
- [ ] **T03** Fix the ALB Cognito action: remove it if D3 makes the ALB internal, otherwise point it at a new confidential app client (`generate_secret = true`, code flow, `openid`, `/oauth2/idpresponse` callback). (3.3)
  - Files: `terraform/alb.tf:257-285`, `terraform/cognito.tf`
- [ ] **T04** Add the missing `aws:SecureTransport = false` condition to the `DenyInsecureTransport` statement. (3.4)
  - Files: `terraform/storage.tf:143-157`
  - Done when: the policy only denies non-TLS requests.
- [ ] **T05** Make the pushed image tag match what ECS pulls: push `:latest` (or an immutable git-SHA tag passed to Terraform as a variable). (3.5)
  - Files: `scripts/build_push.sh:49,167`, optionally `terraform/ecs_services.tf:21` + a new variable
- [ ] **T06** Fix the Cognito demo login: compute `SECRET_HASH` and use the JSON form of `--auth-parameters` (or make the demo client public), and remove `=` and `,` from the demo password alphabet. (3.6)
  - Files: `README.md:946-961`, `terraform/cognito.tf:19` (and `:171-190` if the client becomes public)
- [ ] **T07** Rewrite the AWS path of `deploy.sh`: ECR first, push, full apply, `aws ecs update-service --force-new-deployment` per service, `aws ecs wait services-stable`, print outputs. No `kubectl` on the AWS path. (3.7)
  - Files: `scripts/deploy.sh`
- [ ] **T08** Make `destroy.sh --kms` touch only this project's key (by Terraform output or tag), or remove the option. (3.8)
  - Files: `scripts/destroy.sh:212-245`, `README.md:1322,1333,1511`
- [ ] **T09** Re-run `terraform fmt -check -recursive` and `terraform validate` after Phase 1.

---

## Phase 2: Close the design gaps

- [ ] **T10** Raise `api-gateway` and `inventory-app` to `desired_count = 2` and `min_capacity = 2`; update the cost table. (5.1)
  - Files: `terraform/ecs_services.tf:224,286`, `terraform/autoscaling.tf:28,58`, `terraform/variables.tf`, `README.md`
- [ ] **T11** Decide on `billing-app` `desired_count` drift: add `ignore_changes = [desired_count]` or document why not. (5.1)
  - Files: `terraform/ecs_services.tf:345-396`
- [ ] **T12** Fix the "ALB Target Health" dashboard widget: add the `TargetGroup` dimension, one line per target group. (5.3)
  - Files: `terraform/cloudwatch.tf:407-408`
- [ ] **T13** Add a CloudWatch Logs Insights widget (errors per service, recent 5xx) to the dashboard. (5.3)
  - Files: `terraform/cloudwatch.tf`
- [ ] **T14** Add alarms for the queue consumer: `billing-app` running task count below 2, and `MessageCount` staying high. (5.3)
  - Files: `terraform/cloudwatch.tf`
- [ ] **T15** Enable ALB access logs to the S3 bucket, with a bucket policy statement for ELB log delivery (after T04). (5.3)
  - Files: `terraform/alb.tf`, `terraform/storage.tf`, `README.md` (the bucket now has a real use)
- [ ] **T16** Optional: make `billing-app` readiness reflect the consumer connection, not only the database. (5.3)
  - Files: `srcs/billing-app/app/__init__.py`, `srcs/billing-app/app/consume_queue.py`
- [ ] **T17** Add `sslmode=require` to both database URLs (`query={"sslmode": "require"}` in `URL.create`); keep the local stack working (local Postgres has no TLS, so make it an env-driven default such as `DB_SSLMODE`). (5.4)
  - Files: `srcs/inventory-app/app/__init__.py:148`, `srcs/billing-app/app/__init__.py:224`, `terraform/ecs_services.tf`, `.env.example`
- [ ] **T18** Optional: per-app least-privilege database roles instead of the RDS master user. (5.4)
- [ ] **T19** Fix the stale budget text (300 USD / 260 USD) in `terraform/cloudwatch.tf:443-446,489`. (5.3)
- [ ] **T20** Recompute the monthly cost after T01 and T10; update `var.monthly_budget_limit`, the README cost table and the tfvars example together. (5.6)

---

## Phase 3: Demo and audit tooling

- [ ] **T21** Create an AWS demo script (e.g. `scripts/aws-demo.sh` or `make aws-*` targets) with one section per live question: verify (V1-V2), load balancing (V3), 401 and Cognito (S2-S3), POST/GET movies (F1-F2), billing drill (B1-B2), load test (O1-O2), security evidence (S1). (4)
- [ ] **T22** Inside T21, implement the billing drill with the autoscaler handled: set min capacity 0 or suspend scaling, scale `billing-app` to 0, POST through API Gateway, show `MessageCount`, scale back to 2, show the order via `GET /api/billing/orders` and the logs, restore scaling. (4.7)
- [ ] **T23** Add an AWS mode to `scripts/run-audit-checks.sh` and `scripts/step_by_step_audit.py` covering the new questions, keeping PASS / FAIL / INVALID semantics. (6.3)
- [ ] **T24** Update `scripts/test_cloud.sh:53-59` and every `docs/audit.md` reference in the scripts according to D4. (6.3)

---

## Phase 4: Deploy and verify on AWS

- [ ] **T25 [YOU]** Create AWS credentials for this project in a dedicated profile (not `code-keeper`) and `export AWS_PROFILE=...`. (4.1)
- [ ] **T26 [YOU]** Enable "Receive CloudWatch billing alerts" in the Billing console; keep the region `us-east-1` for the `EstimatedCharges` alarm. (4.1)
- [ ] **T27 [YOU]** Install the Session Manager plugin (for `aws ecs execute-command`). Optional: `kubectl` + `k3d` for the Kubernetes bonus path. (4.1)
- [ ] **T28 [YOU]** If D1 = A: register or select the domain and hosted zone. (3.2)
- [ ] **T29 [YOU]** Create `terraform/terraform.tfvars`: `alarm_email`, `allowed_origins`, domain settings; confirm the SNS subscription email after apply. (4.1)
- [ ] **T30 [AWS]** `terraform init`, `plan -out=tfplan`, `apply tfplan`; push images; force new deployments; wait for stable. (4.2)
- [ ] **T31 [AWS]** Fix anything the first apply reveals; check the lower-confidence items: Cloud Map `container_port` with A records, the MQ console port (15671 vs another), RDS 16.9 availability. (5.5)
- [ ] **T32 [AWS]** Run `terraform plan` again and capture **"No changes"**. (4.2)
- [ ] **T33 [AWS]** Capture V1/V2 evidence: `aws ecs describe-services`, `list-tasks`, `describe-tasks`, `elbv2 describe-target-health`, `aws logs tail`, `rds describe-db-instances`, `mq describe-broker`; plus local `docker ps` with the Fargate explanation. (4.3)
- [ ] **T34 [AWS]** Capture V3 evidence: two healthy targets in two AZs and a measured per-target request split. (4.4)
- [ ] **T35 [AWS]** Capture S2/S3 evidence: 401 without a token, 401 with a bad token, 200 with a valid token; `get-authorizers`, `get-routes`, `describe-user-pool`. (4.5)
- [ ] **T36 [AWS]** Capture F1/F2 evidence: POST a movie (with `description`, not `year`) and GET it back through API Gateway. (4.6)
- [ ] **T37 [AWS]** Run the billing drill from T22 and capture B1/B2 evidence. (4.7)
- [ ] **T38 [AWS]** Load test through API Gateway; capture scale-out and scale-in (scaling activities, service events, dashboard), plus the `billing-app` queue-depth scale-out. Record requests per second, p95 and task count. (4.8)
- [ ] **T39 [AWS]** Capture S1 evidence: HTTP 301, TLS policy, DB not public, DB security group and route table, failed `psql` from outside, Inspector or ECR scan findings, encryption at rest. (4.9)
- [ ] **T40 [AWS]** After a day of running, capture the real spend from Cost Explorer or `aws ce get-cost-and-usage`. (5.6)

---

## Phase 5: Documentation

- [ ] **T41** Apply the README corrections table: broker mode, 18 vs 19 files, push tag, stale `tfplan` re-apply, VPC Link chain claim, `initiate-auth`, test count, `kubectl get hpa,pdb`, budget 300 vs 450, `--kms` text. (6.1)
- [ ] **T42** Add the component-name mapping from D5 to the README component table. (6.1)
- [ ] **T43** Replace the "verified on this machine" tables and audit tallies with numbers re-run on this machine, or reword them. (6.1)
- [ ] **T44** Add a "Verified on AWS" section with the real output from T32 to T40. (6.1)
- [ ] **T45** Add the AWS usage sections: 401 test, billing drill, load test; extend Prerequisites (Session Manager plugin, billing alerts, domain if D1 = A). (6.1)
- [ ] **T46** Update every `docs/readme.md` / `docs/audit.md` reference in `README.md`, `terraform/*.tf` comments and `manifests/` comments according to D4. (6.1)
- [ ] **T47** Replace `ecs-tasks/*.json` with the real task definitions exported after deploy, dropping the three never-deployed ones, or delete the folder and point to `terraform/ecs_services.tf`. (6.4)
- [ ] **T48** Update the architecture diagrams for D2 and D3 (broker mode, internal ALB, removed ALB Cognito action).
- [ ] **T49 [YOU]** In `docs/` (read-only for me): apply D4 (replace or keep the old brief and rubric). (6.2)
- [ ] **T50 [YOU]** In `docs/AUDIT_GUIDE.md`: add answers for V1, F1, F2, B1, B2, S1 (DB restricted to the VPC), S2, S3; update Q5, Q6, Q7, Q9 and the availability pillar after Phases 1 and 2. (6.2)
- [ ] **T51 [YOU]** Decide whether `docs/HANDOFF.md` stays in the submission. (6.2)

---

## Phase 6: Role-play rehearsal

- [ ] **T52** Update the spoken answers for the changed design (broker, edge, cost, availability numbers). (7)
- [ ] **T53** Prepare short answers for the live parts: what each `aws ecs` command proves, no `docker ps` on Fargate, why the queue keeps orders, why `/health` is public. (7)
- [ ] **T54** Prepare the "what would you change" answer with the honest residuals: plaintext inside the VPC, single region, local Terraform state without S3 backend or locking, no CI/CD. (7)
- [ ] **T55 [AWS]** Do one full timed rehearsal of the demo against the live stack. (7)

---

## Phase 7: Bonus (optional)

- [ ] **T56** FaaS: a small Lambda, e.g. subscribed to the SNS alert topic and posting to a chat webhook, or a scheduled CloudWatch log export to S3. (8)
- [ ] **T57** CDN: CloudFront in front of API Gateway; add WAF on CloudFront if wanted (WAF cannot attach to an HTTP API directly). (8)

---

## Phase 8: Commit and teardown

- [ ] **T58 [YOU]** Commit the work yourself (I only run read-only git commands). For example, after reviewing `git status` and `git diff`:
  ```bash
  git add progress.md tasklist.md CHANGELOG.md
  git commit -m "docs: add gap analysis and task list for the cloud-design audit"
  ```
- [ ] **T59 [AWS]** Right after the audit: `terraform destroy`, then run the "verify nothing is left billing" commands (VPCs, RDS, MQ, load balancers, NAT gateways, ECR, S3, KMS). (4.10)
- [ ] **T60** `make down-v` for the local stack if it is no longer needed.
