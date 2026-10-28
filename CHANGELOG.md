# Changelog

History of the changes made in this project, oldest first. Each entry says what changed, why,
and when. New entries are appended at the bottom.

## 2026-10-27 19:18 EET: Gap analysis against the audit questions

**What**
- `progress.md`: created. Lists what remains to meet `docs/cloud-design-questions.md`: a status table per audit question, eight apply or runtime blockers (Amazon MQ deployment mode, API Gateway to ALB protocol, ALB Cognito client secret, S3 bucket policy, image tag mismatch, Cognito login command, `deploy.sh` AWS flow, `destroy.sh --kms` scope), the live AWS demo steps, design gaps, README and script corrections, role-play preparation, bonus ideas and a suggested order of work.
- `CHANGELOG.md`: created with this entry.

**Why**
The user asked for a review of the whole repository against the new brief and audit questions, written to `progress.md`. No project code, Terraform, scripts or `docs/` files were changed.

**Verified**
`terraform init -backend=false`, `terraform validate` and `terraform fmt -check` passed on a temporary copy of `terraform/` outside the project (Terraform v1.16.7, AWS provider 5.100.0). The MQ deployment-mode and API Gateway TLS findings were checked against AWS documentation. No AWS API calls were made.

**Sources**
- [Deployment options for Amazon MQ for RabbitMQ brokers](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-broker-architecture.html): RabbitMQ brokers are single-instance or cluster only, so `ACTIVE_STANDBY_MULTI_AZ` does not apply.
- [Amazon MQ for RabbitMQ broker instance types](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rmq-broker-instance-types.html) (search result): `mq.m7g.medium` is listed for both single-instance and cluster deployments.
- [Amazon API Gateway v2 API reference: Integrations](https://docs.aws.amazon.com/apigatewayv2/latest/api-reference/apis-apiid-integrations.html): an HTTP API private integration's `TlsConfig` has only `serverNameToVerify`, with no option to skip certificate verification.
- [AWS re:Post Knowledge Center: Cognito user pool for ALB authentication](https://repost.aws/knowledge-center/cognito-user-pool-alb-authentication): the app client used by the ALB needs a client secret.
- [AWS re:Post: ALB with a Cognito app client that has no secret](https://www.repost.aws/zh-Hans/questions/QUK-JMwnAjQ2GGyvShw7Rm6g/unable-to-configure-application-load-balancer-using-cognito-client-app-which-has-no-secret) (community answer): same point; a secret cannot be added to an existing client.
- [AWS CloudFormation: ECS Service ServiceRegistry](https://docs.aws.eu/AWSCloudFormation/latest/TemplateReference/aws-properties-ecs-service-serviceregistry.html) (search result): port rules for `service_registries`. It did not settle the A-record case, so `progress.md` words that finding as "if ECS rejects it".

## 2026-10-27 19:23 EET: Task list derived from the gap analysis

**What**
- `tasklist.md`: created. 65 checkbox items in nine phases: 5 decisions (D1-D5) and 60 tasks (T01-T60) covering the apply blockers, design gaps, demo and audit tooling, the live AWS deployment and evidence capture, documentation, role-play rehearsal, optional bonus work, commit and teardown. Each task points back to its section in `progress.md`, and items needing the user (AWS account, domain, decisions, git, `docs/` edits) or a live AWS stack are marked.

**Why**
The user asked for an actionable task list in `tasklist.md` to go with `progress.md`. No project code, Terraform, scripts or `docs/` files were changed.

## 2026-10-27 19:30 EET: Phase 0 decisions settled on cost, all files kept

**What**
- `tasklist.md`: Phase 0 rewritten with the five decisions taken: D1 no domain (free; HTTPS at API Gateway, plain HTTP inside the VPC to the ALB), D2 Amazon MQ `SINGLE_INSTANCE`, D3 internal ALB, D4 keep both the old and the new brief and rubric (new pair authoritative) plus `docs/HANDOFF.md`, D5 keep current component names and document the mapping. Added a note on further cost levers that were deliberately not applied. Dependent tasks updated to match: T01, T02, T03, T08, T24, T28 (skipped, no domain), T29, T39, T40, T45, T46, T47 (keep every `ecs-tasks/` file), T48, T49, T51 (marked done), T52, T54, T56, T57.
- `progress.md`: added a "Decisions taken" section near the top saying which earlier recommendations these choices replace.

**Why**
The user asked for the cheapest, ideally free, option in every Phase 0 decision and for all files to be kept. No project code, Terraform, scripts or `docs/` files were changed.

## 2026-10-27 20:23 EET: Phase 1 Terraform blockers T01-T04 fixed

**What**
- `terraform/amazon_mq.tf`: broker `deployment_mode` is now `SINGLE_INSTANCE` in one private DB subnet (was `ACTIVE_STANDBY_MULTI_AZ`, which Amazon MQ for RabbitMQ rejects); the comment states the single-AZ trade-off.
- `terraform/alb.tf`: rewritten. The ALB is internal, in the private app subnets, with one listener `aws_lb_listener.main` (HTTP :80 by default, HTTPS :443 with ACM when `enable_acm_certificate = true`) and one rule `billing_orders`. Removed: the Cognito login action, the :80 redirect listener, the `vpc_link_hop` source-IP rule, the self-signed certificate resources and the Route 53 alias record.
- `terraform/api_gateway.tf`: the integration targets `aws_lb_listener.main` and gets a `tls_config` (server name `alb_domain_name`) on the ACM path.
- `terraform/security_groups.tf`: removed both `0.0.0.0/0` ALB ingress rules; the VPC Link rule follows the listener port.
- `terraform/cognito.tf`: removed the two `/oauth2/idpresponse` callback URLs.
- `terraform/storage.tf`: `DenyInsecureTransport` now has the `aws:SecureTransport = false` condition.
- `terraform/outputs.tf`: `alb_https_url` replaced by `alb_listener`, `app_base_url_via_alb` removed, descriptions updated.
- `terraform/main.tf` and `terraform/.terraform.lock.hcl`: the unused `tls` provider removed (lock file regenerated by `terraform init`).
- `terraform/variables.tf`, `terraform/terraform.tfvars.example`, `terraform/ecs_services.tf`, `terraform/service_discovery.tf`: descriptions, cost estimate (~$295 steady, ~$335 peak) and listener references updated.
- `scripts/test_cloud.sh`, `scripts/run-audit-checks.sh`: the security-group check now expects no world-open ingress rule, guarded by a parser self-test; the HTTPS section checks the internal ALB and the ACM/tls_config path instead of the old redirect listener. `scripts/step_by_step_audit.py`: matching grep for that step.
- `README.md`: intro, three diagrams, component table, availability, security, prerequisites, tfvars table, cost table, "what I would change" and "real gaps" updated for the single broker and internal ALB; resource and output counts (134 resources, 40 outputs) and the `main.tf` line reference corrected.
- `tasklist.md`: T01-T04 and T48 ticked with notes; T09 annotated.

**Why**
The user asked to start Phase 1 with the Terraform blockers, beginning with T01. The Phase 0 decisions (single broker, no domain, internal ALB) shaped each fix. The self-signed certificate was dropped instead of kept because an API Gateway HTTP API cannot skip certificate verification, so it could never be used.

**Verified**
On a temporary copy outside the project: `terraform fmt -check -recursive` clean, `terraform validate` passes, and a `terraform test` with a mocked AWS provider passes plan runs for both `enable_acm_certificate = false` and `true` (listener protocol and port, tls_config, security group port, broker mode and subnet count, S3 policy condition, Cognito callbacks, outputs). Both audit suites were run on a copy before and after: no new failures (the static suite gives 63 passed, 0 failed with Terraform initialised). No AWS API calls were made, so a real `terraform plan` is still to be run. `docs/AUDIT_GUIDE.md` still describes the old design and was not touched.

**Sources** (checked during the gap analysis)
- [Deployment options for Amazon MQ for RabbitMQ brokers](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-broker-architecture.html): basis for `SINGLE_INSTANCE`.
- [Amazon API Gateway v2 API reference: Integrations](https://docs.aws.amazon.com/apigatewayv2/latest/api-reference/apis-apiid-integrations.html): basis for dropping the self-signed certificate and for the `tls_config` on the ACM path.
- [AWS re:Post Knowledge Center: Cognito user pool for ALB authentication](https://repost.aws/knowledge-center/cognito-user-pool-alb-authentication): basis for removing the ALB Cognito action, which used a client without a secret.

## 2026-10-28 00:03 EET: Phase 1 T05, pushed image tags now match what ECS pulls

**What**
- `scripts/build_push.sh`: local builds keep the `:local` tag; `--push` now sends each application image to ECR as `:latest` and as an immutable build tag (git short SHA, with a `-dirty-<UTC time>` suffix when `srcs/` has uncommitted changes; `IMAGE_TAG` overrides it and is validated against the ECR tag rules). The closing message says how to roll the services onto the push. `--help` now prints the whole header (it used to stop before the last usage lines).
- `terraform/variables.tf`: new variable `image_tag` (default `latest`, regex validation); 34 variables now.
- `terraform/ecs_services.tf`: `local.ecr_image_urls` uses `var.image_tag` instead of a hard-coded `:latest`, with a FIX comment.
- `terraform/ecr.tf`: push-workflow comment points at `build_push.sh` and explains why the repositories stay MUTABLE.
- `terraform/terraform.tfvars.example`: `image_tag = "latest"` with a comment.
- `README.md`: AWS walkthrough step 5 no longer re-runs the already applied `tfplan`; it pins the SHA with `-var image_tag=...` or forces a redeploy of each service and waits for `services-stable`. Added a `jq` prerequisite row, the build_push.sh table row, and 33 -> 34 variables in two places.
- `tasklist.md`: T05 ticked with a note; T09 note records the re-run.

**Why**
The push sent `:local` while the task definitions pulled `:latest`, so every ECS task would fail with CannotPullContainerError. Both options from the task are in place: `:latest` works with no change, and the SHA tag gives a new task definition revision and a record of which build runs. `:local` stays because docker-compose.yml and deploy-k3d.sh depend on it.

**Verified**
- Stubbed `docker`/`aws`/`terraform` dry runs in `/tmp`: pushes `latest` + `0b1188f` for the three app repos and skips the other three; `IMAGE_TAG=latest` pushes once; `IMAGE_TAG=-bad` exits 1; dirty `srcs/` gives a `-dirty-...` tag; no git gives `build-<time>`.
- Temp Terraform copy: `fmt -check` clean, `validate` passes, mocked `terraform test` 5 passed (two edge runs from T01-T04 plus `image_tag` default, pinned and invalid).
- Initialised temp copy of the repo: `test_cloud.sh` 63 passed, 0 failed; `run-audit-checks.sh --static` PASS=159 FAIL=0 INVALID=8.
- No real build, push or `terraform plan` (needs AWS credentials).

## 2026-10-28 00:30 EET: Phase 1 T06, Cognito demo login command fixed

**What**
- `README.md`: the "Obtain a JWT" block no longer passes `--secret` (not an `initiate-auth` option). It computes `SECRET_HASH` with `openssl` (HMAC-SHA256 of username + client id, keyed with the client secret, Base64) and sends `USERNAME`, `PASSWORD` and `SECRET_HASH` as JSON built by `jq`. The note under it now says correctly how `terraform output` shows the sensitive password (`-raw` prints it; `-json` quotes it and escapes `&`) and what `None` in `AUTH` means. The prerequisites row now lists `jq` and `openssl`.
- `terraform/cognito.tf`: `=` removed from the demo password `override_special` (now `!#$%&*()-_+`), with a FIX comment; the demo-client comment rewritten, since the old one claimed `initiate-auth` needs a client secret (it needs `USER_PASSWORD_AUTH`, which the PKCE client does not allow).
- `terraform/terraform.tfvars.example`: points at `terraform output -raw` instead of `-json` for the demo password.
- `tasklist.md`: T06 ticked with a note; T41 notes which of its README corrections are already done.

**Why**
The documented login failed at once with `Unknown options: --secret`, and without `SECRET_HASH` Cognito refuses any call to a client that has a secret, so the managed-authentication demo could not be shown. The client keeps its secret (free either way, and smaller than turning it into a second public client). JSON built by `jq` works for any password, including one an operator sets.

**Verified**
- Local only, dummy credentials, no AWS calls: AWS CLI 2.38.2 rejects `--secret`; in shorthand a `,` in the password turns it into a list (an `=` survives); the JSON form reaches the request body unchanged; the `openssl` hash matches a Python HMAC reference.
- The exact README block, run against a local mock Cognito that recomputes `SECRET_HASH`, returned the token for a generated-style password and for an operator password containing `, = " \` and a space; a wrong hash was rejected.
- Temp Terraform copy: `fmt -check` clean, `validate` passes, mocked `terraform test` 6 passed (new run checks the alphabet and that the demo client stays confidential with USER_PASSWORD_AUTH).
- Initialised temp copy of the repo: `test_cloud.sh` 63 passed, 0 failed; `run-audit-checks.sh --static` PASS=159 FAIL=0 INVALID=8.
- Not run against real Cognito (needs a deployed stack).

## 2026-10-28 10:37 EET: Phase 1 T07, deploy.sh AWS path rewritten for ECS

**What**
- `scripts/deploy.sh`: rewritten. Live order: prerequisites (aws, terraform, docker, jq), `sts get-caller-identity`, `terraform init`/`validate`/`fmt -check`, region read from `var.aws_region` (dies if a `REGION` env var disagrees), then a full `terraform plan`, stopping there unless `AUTO_APPROVE=true`. With it: `apply -target=aws_ecr_repository.app`, `build_push.sh --push`, a check that `:latest` exists in all three repos, a fresh `plan -out=tfplan` + `apply tfplan` (the spent plan is then removed), `aws ecs update-service --force-new-deployment` per service, `aws ecs wait services-stable` (on failure it prints the last 5 events per service), a warning if `var.image_tag` is not `latest`, and the demo outputs. No `kubectl` anywhere. `--static-only` now makes no AWS call: it builds one image and runs `terraform init`/`validate`/`fmt -check`. `PUSH` is gone (the AWS path always pushes).
- `scripts/build_push.sh`: `NEXT_HINT=0` hides the "Next, move the ECS services" hint (deploy.sh does those steps itself); `sts get-caller-identity` asks for `--output json` so `jq` can parse it whatever the CLI default output is.
- `manifests/namespace.yaml`, `manifests/kustomization.yaml`: comments no longer say `deploy.sh` applies the manifests; they point at `deploy-k3d.sh`.
- `README.md`: AWS walkthrough names `AUTO_APPROVE=true ./scripts/deploy.sh` as the one-command form of steps 3 to 5; the scripts table row describes the new flow.
- `tasklist.md`: T07 ticked and crossed out; the tasks ticked earlier (D1-D5, T01-T06, T48, T51) crossed out too, following the new task-list rule.

**Why**
The old script pushed before the ECR repositories existed (so every image was skipped) and then ran `kubectl apply -k manifests/`, which on an ECS project either failed or hit an unrelated local cluster. The new order puts images in ECR before the services that pull them are created, and only reports success once ECS says the services are stable.

**Verified**
- Stubbed `aws`/`terraform`/`docker` in `/tmp`: the happy path runs the calls in the order above and leaves no `tfplan`; without `AUTO_APPROVE` only `plan` runs; a failed waiter exits 1 with the service events; a missing image exits 1 before the full plan; a `REGION` mismatch exits 1 before any apply; `aws_region = eu-central-1` reaches every aws call and the push; a pinned `image_tag` gives 3 warnings; a bad argument exits 2.
- `--static-only` with the real Terraform binary: exit 0, `validate` passes, 0 aws calls.
- `build_push.sh` alone still prints its hint; with `NEXT_HINT=0` it does not.
- Initialised temp copy of the repo: `test_cloud.sh` 63 passed, 0 failed; `run-audit-checks.sh --static` PASS=159 FAIL=0 INVALID=8.
- Not run against AWS (needs credentials and creates billable resources).

## 2026-10-28 11:18 EET: Phase 1 T08, destroy.sh --kms limited to this project's key; T09 closing check

**What**
- `scripts/destroy.sh`: `--kms` no longer loops over `aws kms list-keys` scheduling every key in the region. Before `terraform destroy` it records the key IDs of `aws_kms_key` resources in Terraform state, plus `var.aws_region`, `var.project_name` and `var.environment`. After a successful destroy it checks those keys: PendingDeletion is reported with its deletion date; a key still Enabled or Disabled is scheduled (7 days). With nothing in state, it reads every key in the region but only matches customer-managed keys carrying all three project tags (`Project`, `Environment`, `ManagedBy = Terraform`). A match is scheduled only after an interactive yes; under `--yes` it is listed with the command, not scheduled. No other key is changed. If the destroy did not run, or the aws CLI, jq or the Terraform values are missing, it only prints the manual commands. Every call uses the Terraform region. The bogus `get-key-randomness` line is gone; the header, `--help` range, closing summary and the KMS verify command (tag-filtered) are corrected. New helper `ask()` returns on "no" instead of exiting.
- `README.md`: cleanup block, "Survives" table row and the teardown paragraph now say a key pending deletion is not billed, and describe what `--kms` really does (the old text said it "cancels that window").
- `tasklist.md`: T08 and T09 ticked and crossed out.

**Why**
`--kms` could schedule the deletion of other projects' keys in the same account, which makes their data unrecoverable after 7 days. And the stated reason for the flag was wrong: AWS KMS pricing says "There is no charge for customer managed KMS keys that you manage and are scheduled for deletion", and `terraform destroy` already schedules this project's key with the 7-day minimum. The flag is now a check plus a safety net for a key the destroy missed.

**Verified**
- Stubbed `terraform`/`aws` in `/tmp` (copy of the script, so the repo's `terraform/` was not touched), with five fake keys (another project's key, an AWS-managed key, a project key pending deletion, an orphaned project key, a key with only some project tags):
  - key in state, PendingDeletion: 0 schedule calls; key in state, Enabled: only that key scheduled;
  - empty state with `--yes`: 0 schedule calls, orphan listed with its command; interactive "y": only the orphan scheduled; "n": none;
  - the AWS-managed key's tags were never read, and all 34 aws calls used the Terraform region;
  - failed destroy: exit 1 with 0 KMS calls; no terraform: 0 aws calls, manual commands printed; without `--kms`: 0 KMS calls.
- T09: no Terraform file changed since the T06 commit; `fmt -check` clean, `validate` passes, mocked `terraform test` 6 passed.
- Initialised temp copy of the repo: `test_cloud.sh` 63 passed, 0 failed; `run-audit-checks.sh --static` PASS=159 FAIL=0 INVALID=8.
- Not run against AWS.

**Sources**
- [AWS KMS pricing](https://aws.amazon.com/kms/pricing/): the quoted sentence that keys scheduled for deletion are not charged.
- [AWS KMS Developer Guide: Delete an AWS KMS key](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html): the 7 to 30 day waiting period and the PendingDeletion key state.

## 2026-10-28 11:27 EET: destroy.sh confirmation now really asks for the account ID

**What**
- `scripts/destroy.sh`: new `confirm_account()`. Before `terraform destroy` it shows the account, identity ARN and region (from `var.aws_region`), and requires the account ID typed back exactly; anything else (including `y`) aborts with exit 2 and nothing destroyed. `terraform init` now runs before the prompt (it changes nothing in AWS) so the region can be read. If `sts get-caller-identity` fails it stops with nothing destroyed; if the aws CLI is not installed it falls back to a y/N prompt that says the account cannot be shown. `--yes` still skips the prompt; no TTY still exits 2. The `--kms` block reuses the region read here.

**Why**
The user asked to fix the mismatch noted after T08: the prompt said "Type the AWS account id to proceed?" but accepted only y/N, so it never checked which account was about to be emptied.

**Verified**
Stubbed `terraform`/`aws` on a copy of the script, prompts answered through `script` (a real TTY): right ID destroys; wrong ID and `y` abort with exit 2 and no destroy; no aws CLI gives the y/N fallback; failing `sts` exits 1 with no destroy; `--yes` destroys with no sts call; no TTY exits 2 with no destroy; `--kms` still works after the right ID. `test_cloud.sh` 63 passed, 0 failed; `run-audit-checks.sh --static` PASS=159 FAIL=0 INVALID=8.

## 2026-10-28 12:40 EET: Phase 2 T10 and T11, two tasks per service and no desired_count drift

**What**
- `terraform/ecs_services.tf`: `api-gateway` and `inventory-app` start with `desired_count = 2` (was 1); `billing-app` gets `lifecycle { ignore_changes = [desired_count] }` like the other two. FIX comments explain why, and how a running stack still reaches 2 (raising `min_capacity` moves current capacity up to it). Header comment updated.
- `terraform/autoscaling.tf`: `min_capacity = 2` (was 1) for the `api-gateway` and `inventory-app` targets; header and target comments updated. Max stays 3 / 3 / 6.
- `terraform/variables.tf`, `terraform/terraform.tfvars.example`: cost estimate now 6 Fargate tasks ~$54, steady state ~$313/month (was ~$295), peak ~$331 (8 tasks). Budget value 450 unchanged (T20).
- `scripts/run-audit-checks.sh`: the autoscaling parser keeps the raw bound and resolves `var.NAME` to the variable default, so the `billing-app` target (written with variables) is checked instead of silently skipped. The `desired_count` checks compare against the parsed `min_capacity` and require at least 2 (the old messages hard-coded "min_capacity=1"). New check: every `aws_ecs_service` has `ignore_changes = [desired_count]`.
- `README.md`: component table, scalability table, autoscaling table (min 2), availability bullet, cost table (6 tasks ~$54, ~$313 steady, ~$331 peak), cost-effectiveness bullet (the stale ~$410 figure), and the Fargate Spot row.
- `tasklist.md`: T10 and T11 ticked and crossed out.

**Why**
With one task each, the internal ALB had a single target to "balance" and one AZ loss took the request path down, so the README's availability claim was not true. `billing-app` was the only service without `ignore_changes`, so any apply after a backlog scale-out reset it to 2 mid-burst. The two extra tasks cost about $18/month together.

**Verified**
- Temp Terraform copy: `fmt -check` clean, `validate` passes, mocked `terraform test` 7 passed (new run: all three services start at 2, all targets keep min 2, max 3 / 3 / 6).
- `run-audit-checks.sh --static` on an initialised copy: PASS=163 FAIL=0 INVALID=8 (159 before: +3 for the billing target now parsed, +1 for the drift check). With `api-gateway` put back to 1 and the `billing-app` `ignore_changes` removed, both new checks FAIL as intended.
- `test_cloud.sh`: 63 passed, 0 failed (reports min=2 max=3).
- Not run against AWS.

**Sources**
- [Application Auto Scaling API: RegisterScalableTarget](https://docs.aws.amazon.com/autoscaling/application/APIReference/API_RegisterScalableTarget.html): capacity below the new minimum is raised to it, which is how a running stack reaches 2 tasks without a `desired_count` change.

## 2026-10-28 13:41 EET: T12-T14 dashboard target health per target group, Logs Insights widgets, queue consumer alarms

**What**
- `terraform/cloudwatch.tf`: the "ALB Target Health" widget now queries `HealthyHostCount` (Minimum) and `UnHealthyHostCount` (Maximum) with `TargetGroup` + `LoadBalancer`, one line each for the api-gateway and billing-app target groups (it used `LoadBalancer` alone, a dimension set the ALB never publishes for these metrics, so it could never show data). Two Logs Insights widgets added at y=18: `[ERROR]`/`[CRITICAL]` line count per service across the three app log groups (service taken from `@log`), and the 20 most recent API Gateway 5xx from the JSON access log. Two alarms added, both to the SNS topic with alarm and OK actions: `billing-app-consumers-below-min` (`ECS/ContainerInsights` `RunningTaskCount` < `var.billing_app_min_capacity`, 3 x 60 s, missing data breaching) and `billing-queue-backlog` (broker `AWS/AmazonMQ` `MessageCount` > 2 x `var.billing_queue_depth_target`, 5 x 60 s, missing data not breaching).
- `scripts/run-audit-checks.sh`: the closing note now counts metric and Logs Insights widgets separately (it counted only `type = "metric"`).
- `README.md`: architecture diagram (13 alarms, 8-widget dashboard), Container Insights note, alarm table and heading (all 13) with the two new rows and an explanation, dashboard section listing all 8 widgets, reading order, cost-tooling and alerting rows (13 alarms).
- `tasklist.md`: T12, T13, T14 ticked and crossed out.

**Why**
Phase 2 monitoring group. The backlog alarm threshold is twice the autoscaling target, so it fires only when added consumers are not catching up; a one-message drill does not trip it (documented in README). Broker-level `MessageCount` is used instead of per-queue dimensions because RabbitMQ 4.x brokers no longer publish the `Queue` and `VirtualHost` dimensions.

**Verified**
`terraform fmt -check`, `terraform validate`; mock `terraform test` 9 passed (new runs `consumer_alarms` and `dashboard_widgets` decode the dashboard JSON); negative check with the old widget restored made `dashboard_widgets` fail. `scripts/test_cloud.sh` 63 passed; `scripts/run-audit-checks.sh --static` PASS=163 FAIL=0 (13 alarms, 8 widgets). No AWS calls; the Logs Insights queries were not run against real logs. Freed space on the full `/tmp` RAM disk by deleting only my own earlier scratch copies (`/tmp/cd-t05` to `/tmp/cd-t10`).

**Sources**
- [CloudWatch metrics for your Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-cloudwatch-metrics.html): `HealthyHostCount` and `UnHealthyHostCount` are published only with `TargetGroup` + `LoadBalancer` (optionally + `AvailabilityZone`).
- [Amazon ECS Container Insights metrics](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-ECS.html): `RunningTaskCount` in `ECS/ContainerInsights` with `ServiceName` + `ClusterName`.
- [Available CloudWatch metrics for Amazon MQ for RabbitMQ brokers](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-logging-monitoring.html): broker-level `MessageCount` with the `Broker` dimension; RabbitMQ 4.x brokers no longer have the `Queue` and `VirtualHost` dimensions.
- [CloudWatch Dashboard Body Structure and Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/CloudWatch-Dashboard-Body-Structure.html): `log` widget properties (`query` starting with `SOURCE`, `region`, `view`) and the `"."` shorthand in metric rows.
- [CloudWatch Logs Insights query syntax: parse](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax-Parse.html): `parse` takes any field, such as `@log`, and supports regex named capture groups.

## 2026-10-28 14:19 EET: Sources added to earlier changelog entries

**What**
- `CHANGELOG.md`: a **Sources** section (linked page plus what it supported) added to the entries for the gap analysis, T01-T04, T08, T10/T11 and T12-T14. Nothing else in those entries changed (27 lines inserted, none removed). The other entries (task list, Phase 0, T05, T06, T07, the destroy prompt fix) got none, because no outside source was consulted for them.

**Why**
The user asked for the sources behind each change to be recorded in the changelog, including earlier tasks, and allowed earlier entries to be edited this one time, only to add the sources. The list comes from the web lookups recorded in this session's transcript, not from memory.
