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

## 2026-10-28 15:04 EET: Phase 2 T15, ALB access logs to the S3 bucket

**What**
- `terraform/alb.tf`: `aws_lb.main` gets an `access_logs` block (bucket = the artifacts bucket, prefix `alb-access-logs`, `enabled = var.enable_artifact_bucket`, so without the bucket logging is explicitly off) and `depends_on = [aws_s3_bucket_policy.artifacts]`, because ELB writes a test file when logging is turned on and because destroy must remove the ALB before the bucket.
- `terraform/storage.tf`: header rewritten (the ALB now writes here; the old "nothing writes to it" text is gone). New `local.alb_access_log_prefix`. `force_destroy = true` on the bucket, since a bucket holding log versions cannot be deleted and `terraform destroy` would stop with BucketNotEmpty. Bucket policy document renamed from `artifacts_tls_only` to `artifacts` and given a third statement, `AllowAlbAccessLogDelivery`: `s3:PutObject` for `logdelivery.elasticloadbalancing.amazonaws.com` on `alb-access-logs/AWSLogs/<account>/*`, with `aws:SourceArn` limited to this account, Region and ALB name. New lifecycle rule `alb-access-logs-expiry`: logs expire after `var.log_retention_days`, noncurrent versions a day later. The encryption comment now says SSE-S3 is required for ALB log delivery.
- `terraform/variables.tf`, `terraform/outputs.tf`, `terraform/terraform.tfvars.example`: `log_retention_days` also sets the S3 log expiry; `enable_artifact_bucket` and the bucket output describe the new use (false turns the access logs off).
- `scripts/destroy.sh`: closing summary lists the S3 bucket (emptied by `force_destroy`) and adds a leftover check, `aws s3api list-buckets` filtered by project name.
- `README.md`: new "ALB access logs (S3)" section (what is logged, the per-target count command, bucket policy, encryption, retention, teardown, cost); S3 added to the system context diagram, its intro and the supporting-resources list; `enable_artifact_bucket` in the tfvars notes; S3 row in the "Survives" table; pointer from the load-distribution verification block. Also corrected the Terraform counts to 136 `resource` blocks (131 `aws_*`) in two places: the two T14 alarms had made the old 134 / 129 stale, and the T12-T14 entry missed it.
- `tasklist.md`: T15 ticked and crossed out.

**Why**
T15: the bucket had no real use, and the ALB access logs give it one and are the AWS-side proof of how requests are spread over the tasks (the local proof is the nginx log). The service principal policy is the form AWS now recommends; the legacy per-Region ELB account was not used. Logs expire with the CloudWatch retention instead of going to GLACIER, which for many small files would cost more than it saves.

**Verified**
- `terraform fmt -check` clean, `terraform validate` passes; mocked `terraform test` 11 passed (new runs `alb_access_logs` and `no_bucket_no_access_logs`), and the plans show no dependency cycle between the ALB and the bucket policy. Negative check (force_destroy off, wrong principal, `AWSLogs` prefix) made `alb_access_logs` fail on three asserts.
- The real bucket policy JSON was rendered with AWS provider 5.100.0 and fake credentials (this data source is computed locally, no AWS call): the new statement matches the AWS example policy plus the `aws:SourceArn` condition.
- `scripts/test_cloud.sh` 63 passed (same 2 warnings as before); `scripts/run-audit-checks.sh --static` PASS=163 FAIL=0.
- Not run against AWS: log delivery, the ELB test file and the destroy of a bucket with objects are unverified until a real deployment.

**Sources**
- [Enable access logs for your Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html): the `logdelivery.elasticloadbalancing.amazonaws.com` policy (the per-Region account policy is legacy), the resource path with `AWSLogs/<account-id>`, the `aws:SourceArn` best practice, SSE-S3 as the only supported encryption, the prefix must not contain `AWSLogs`, the `ELBAccessLogTestFile` check, and disabling logs before deleting the bucket.
- [Access logs for your Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-access-logs.html): one gzip file per node every 5 minutes, best-effort delivery, field 5 is `target:port`, S3 storage is charged but not the delivery bandwidth.
- [How Amazon S3 handles conflicts in lifecycle configurations](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-conflicts.html): the shorter of two overlapping expirations is honored, and deletion takes precedence over transition.
- [terraform-provider-aws v5.100.0, `internal/service/elbv2/load_balancer.go`](https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v5.100.0/internal/service/elbv2/load_balancer.go): with `enabled = false` (or no `access_logs` block) the provider sends `access_logs.s3.enabled = false` and ignores bucket and prefix; `bucket` is required in the block.

Text for the read-only docs (for you to apply):
  - docs/HANDOFF.md:404 becomes:
    - Do not let the docs claim the S3 bucket is used by the application. Only the ALB writes to it (access logs under \alb-access-logs/`);
    no application code does.`
  - docs/AUDIT_GUIDE.md:2263 becomes:
  | **S3 object storage** | `terraform/storage.tf` declares one bucket, toggleable via `var.enable_artifact_bucket` (default on): SSE 
  AES256, versioning, `force_destroy`, full public-access block, lifecycle rules (ALB logs expire after 30 days), and a bucket policy with 
  TLS-only and encrypted-upload denies plus an allow for ELB log delivery. | The internal ALB writes its **access logs** here under 
  `alb-access-logs/`; it is also the archive target for build artefacts and log exports. No application code writes to it: there is no 
  `boto3` call anywhere in `srcs/` and no task-definition mount. Do not claim the app uses it. |

## 2026-10-28 18:29 EET: T15 docs text recorded, docs not changed yet

**What**
- `CHANGELOG.md`: this entry stores the replacement text for the two lines in the read-only docs that T15 made stale, so it is kept until the docs are edited. No file in `docs/` was changed. The unheaded text at the end of the T15 entry above is the same text pasted from the terminal and was left as it is; its table row is wrapped over five lines and a backtick was lost on its first line, so copy from the blocks below instead.

Pending docs changes:

1. `docs/HANDOFF.md:404` says nothing writes to the bucket; the ALB now does. Replace the line with:

```
- Do not let the docs claim the S3 bucket is used by the application. Only the ALB writes to it (access logs under `alb-access-logs/`); no application code does.
```

2. `docs/AUDIT_GUIDE.md:2263`, the S3 row: it lacks `force_destroy`, the log expiry rule and the ELB log delivery statement, and names only artefacts and log archival as uses. Replace the row with:

```
| **S3 object storage** | `terraform/storage.tf` declares one bucket, toggleable via `var.enable_artifact_bucket` (default on): SSE AES256, versioning, `force_destroy`, full public-access block, lifecycle rules (ALB logs expire after 30 days), and a bucket policy with TLS-only and encrypted-upload denies plus an allow for ELB log delivery. | The internal ALB writes its **access logs** here under `alb-access-logs/`; it is also the archive target for build artefacts and log exports. No application code writes to it: there is no `boto3` call anywhere in `srcs/` and no task-definition mount. Do not claim the app uses it. |
```

Checked, no change needed:
- `docs/HANDOFF.md:78-79`: still true; `ecs_services.tf` has no reference to `storage.tf` (only `alb.tf` and `outputs.tf` reference the bucket) and no application code writes to S3.
- `docs/HANDOFF.md:258-260`: still true; it says the application does not write to the bucket, and ALB logs fall under the log archival it names.
- `docs/AUDIT_GUIDE.md:1536`: `storage.tf=7` is a per-file resource count, and `storage.tf` still has 7 `resource` blocks.

**Why**
The user decided not to edit the read-only docs yet and asked for the T15 docs text to be recorded in the changelog as well. Fenced blocks keep the Markdown exact when copied.

**Verified**
Read the current lines in `docs/HANDOFF.md` and `docs/AUDIT_GUIDE.md` (read only) and searched `docs/` for other claims that nothing writes to the bucket: only the lines above. Resource count from `grep -c '^resource ' terraform/storage.tf` (7, same as at HEAD).

## 2026-10-28 18:32 EET: T12-T14 docs text recorded, docs not changed yet

**What**
- `CHANGELOG.md`: this entry stores the replacement text for the lines in `docs/AUDIT_GUIDE.md` (read-only) that T12-T14 made stale: the dashboard grew from 6 to 8 widgets, and the alarms from 11 to 13, which puts `cloudwatch.tf` at 22 resources. The text was given in chat after T12-T14 and is now written out as whole replacement lines. No file in `docs/` was changed.

Pending docs changes in `docs/AUDIT_GUIDE.md`:

1. Lines 550-553, the "A 6-widget dashboard" bullet. Replace the four lines with:

```
- **An 8-widget dashboard** `cloud-design-prod-observability`: API Gateway traffic
  + 4xx/5xx; ALB request volume and target latency; both RDS instances' CPU and
  connections; RabbitMQ `MessageCount`; ALB healthy/unhealthy targets per target
  group; ECS per-service CPU; and two Logs Insights widgets (errors per service,
  recent API Gateway 5xx).
```

2. Line 1126. Replace with:

```
| Monitoring | 13 alarms, 8-widget dashboard, 4 log groups, SNS topic **with a policy** |
```

3. Line 1790. Replace with:

```
Every one of the 13 alarms has `alarm_actions` pointing at an SNS topic **that has a
```

4. Line 2740. Replace with:

```
| `cloudwatch.tf` | 22 | 4 log groups, SNS topic + topic policy + email subscription, 13 alarms, 8-widget dashboard, budget, billing alarm |
```

5. Line 2766. Replace with:

```
| `:84` monitoring | 4 log groups with retention; 13 alarms; SNS topic **with** topic policy (13 alarm actions); 8-widget dashboard; `aws_api_gateway_account` | STATIC |
```

Not covered here: some lines next to these hold numbers that earlier tasks made stale, for example line 1124 (142 resources, 33 variables; now 34 variables), line 2739 (autoscaling min 1, now min 2, and 6 resources in `autoscaling.tf`) and line 2767 (`desired_count` 1/1/2, now 2/2/2). They belong to the T50 docs pass.

**Why**
The user asked for the T12-T14 docs text to be recorded in the changelog the same way as the T15 text, so it is kept until the read-only docs are edited.

**Verified**
Read the current lines 550-553, 1124-1126, 1790, 2739-2741 and 2766-2767 (read only); `grep` over `docs/` found no other line with the old alarm or widget counts. Counts checked against the Terraform at HEAD (05187af): 22 `resource` blocks in `cloudwatch.tf`, 13 `aws_cloudwatch_metric_alarm` (all in `cloudwatch.tf`) with 13 `alarm_actions`, 6 metric plus 2 log widgets, 4 log groups, 34 variables, 6 resources in `autoscaling.tf`.

## 2026-10-28 19:07 EET: Phase 2 T16, billing-app /ready also requires the queue consumer

**What**
- `srcs/billing-app/app/consume_queue.py`: `start_consuming()` takes an optional `connected_event`. It is set once `basic_consume()` has returned (pika waits there for the broker's ConsumeOk) and cleared in a `finally` around `start_consuming()`, so it drops the moment the connection is lost or the consumer stops, before the 3 s retry pause.
- `srcs/billing-app/app/__init__.py`: `create_app()` takes an optional `consumer_connected` Event. `/ready` adds `"consumer": "connected"` or `"disconnected"` and returns 503 with a fixed message (`CONSUMER_UNAVAILABLE_MESSAGE`, no broker hostname) when the consumer is not registered. The database check and its 503 body are unchanged; without an Event, readiness is the database alone, as before. Comments say which probes read `/ready` and why ECS stays on `/health`.
- `srcs/billing-app/server.py`: creates the Event and passes it to both.
- `srcs/billing-app/tests/test_shutdown.py`: the fake channel can raise from `start_consuming()`; new class `ConsumerConnectedEventTest` (3 tests).
- `srcs/billing-app/tests/test_readiness.py`: new, dependency-free like the other suites (Flask, SQLAlchemy and `app.orders` stubbed), 5 tests of the `/ready` answers.
- `srcs/billing-app/Dockerfile`, `manifests/billing-app.yaml`: the HEALTHCHECK and readinessProbe comments describe the new check; the manifest's stale note that the `/ready` route did not exist yet is gone.
- `terraform/ecs_services.tf`: comment only, on why billing-app's ECS health check stays on `/health`.
- `scripts/run-audit-checks.sh`: the live compose section shows the billing-app `/ready` body and asserts `"consumer":"connected"`.
- `README.md`: defect 5 (liveness vs readiness) describes the consumer check, with the line reference corrected to `srcs/billing-app/app/__init__.py:132-179`; new "Real gaps" bullet: on ECS nothing probes `/ready`, and a `ConsumerCount` alarm would be the direct AWS signal (not added).
- `tasklist.md`: T16 ticked and crossed out.

**Why**
T16: `/health` and `/ready` both answered 200 while the consumer thread had lost the broker, so a task consumed nothing and looked healthy. Readiness, not liveness, carries the check, because restarting a consumer cannot fix a broker outage; for the same reason the ECS health check and the ALB stay on `/health`. The new signal therefore shows in `docker ps` (unhealthy), the compose healthcheck and `kubectl get pods` (0/1 READY); on AWS a lost broker still shows only in the logs and the backlog alarm.

**Verified**
- `make test-py`: 60 tests OK (billing-app 32 to 40, inventory-app 20). Negative check on a scratch copy (consumer check removed from `/ready`, Event cleared only after the retry sleep): 3 of the new tests fail.
- Live on local Docker with the real code, pika, Flask, PostgreSQL 17 and RabbitMQ 3.13 (scratch compose project `cd-t16`, own image tags, no host ports): broker up, `/ready` 200 `{"consumer":"connected","database":"reachable","status":"ready"}`; broker stopped, 503 `"consumer":"disconnected"` within 2 s, container `unhealthy` when checked 70 s later, `/health` still 200, 0 restarts; broker started, 200 again after 44 s (mostly broker start-up) and container `healthy`.
- Cleanup: everything that run created was removed, namely the containers (including the pinned names `cloud-design-rabbit-queue` and `cloud-design-billing-database`), volumes, network, the `cd-t16/*` images and the two base images it pulled (`postgres:17-alpine`, `rabbitmq:3.13-management-alpine`). The Docker build cache was left. Image count is back to 17; the user's other containers were not touched.
- Terraform `fmt -check`, `validate`, mocked `terraform test` 11 passed. `test_cloud.sh` 63 passed (same 2 warnings); `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51, its `make test-py` step now reporting 60 tests. The new audit assertion was checked against the real connected and disconnected bodies, not in a full live audit run.
- Not run: k3d (no kubectl here) and ECS.

**Sources**
- [pika 1.3.2, `pika/adapters/blocking_connection.py`](https://raw.githubusercontent.com/pika/pika/1.3.2/pika/adapters/blocking_connection.py): `BlockingChannel.basic_consume()` waits in `_flush_output(ok_result.is_ready)` for Basic.ConsumeOk, the basis for setting the Event right after it.
- [Scheduling the maintenance window for an Amazon MQ broker](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/maintaining-brokers.html): maintenance can last up to two hours and only the highly available deployment modes minimize the downtime; the reason given in `ecs_services.tf`.
- [Available CloudWatch metrics for Amazon MQ for RabbitMQ brokers](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-logging-monitoring.html): `ConsumerCount` is a broker-level metric with the `Broker` dimension (README gap bullet).

Pending docs text (read-only, not applied). No docs line became wrong; this one addition is optional. `docs/AUDIT_GUIDE.md:1329`, replace the line with these two:

```
and `/ready` is the endpoint that checks `SELECT 1` (on `billing-app` it also checks
that the queue consumer is registered with the broker), unlike `/health`, which is
```

## 2026-10-28 19:51 EET: Phase 2 T17, sslmode=require on both database URLs

**What**
- `srcs/inventory-app/app/__init__.py`, `srcs/billing-app/app/__init__.py`: new `_db_sslmode()` reads `DB_SSLMODE` (default `require`; case and spaces ignored; an unknown value logs a warning and falls back to `require`, never to a weaker mode). `create_app()` logs the mode and passes it as `query={"sslmode": ...}` in `URL.create`, which SQLAlchemy hands to libpq.
- `terraform/ecs_services.tf`: `DB_SSLMODE = "require"` in the inventory-app and billing-app task definitions (also the code default; set so the task definition shows it). `terraform/rds.tf`: the client-side comment now describes this instead of calling it open application work.
- `docker-compose.yml` (`DB_SSLMODE: ${DB_SSLMODE:-prefer}` for both apps), `.env.example` (`DB_SSLMODE=prefer` with a comment), `manifests/configmap.yaml` (`DB_SSLMODE: "prefer"`): the local PostgreSQL containers have no TLS, so the local stacks keep `prefer`, libpq's own default and what the apps used until now.
- `ecs-tasks/inventory-app-task.json`, `ecs-tasks/billing-app-task.json`: the same `DB_SSLMODE = require` entry, so the placeholders match Terraform.
- `srcs/inventory-app/tests/test_db_sslmode.py`, `srcs/billing-app/tests/test_db_sslmode.py`: new, dependency-free (stubbed Flask and SQLAlchemy), 5 tests each on the `query` the real `create_app()` passes to `URL.create`.
- `scripts/test_cloud.sh`: new check next to the `rds.force_ssl` one: both task definitions set `DB_SSLMODE = require` and both apps pass sslmode into `URL.create`.
- `README.md`: the in-transit bullet, both environment-variable tables (`DB_SSLMODE` rows), the "what I would change" item (now `verify-full` with the RDS CA bundle) and the "Real gaps" bullet (now: TLS always, server certificate not verified).
- `tasklist.md`: T17 ticked and crossed out.

**Why**
T17: TLS to RDS relied on libpq's `prefer` default meeting a `force_ssl = 1` server. With `require` the client never offers plaintext either, so the control holds at both ends. The default lives in the code (fail closed if the variable is missing), and only the local stacks opt down to `prefer`. `require` encrypts but does not check the server certificate; `verify-full` would need the RDS CA bundle in the images and is left as the next step.

**Verified**
- `make test-py`: 70 tests OK (inventory-app 20 to 25, billing-app 40 to 45). Negative check on a scratch copy (the `query=` line removed from both apps): 5 errors in each suite, and the new `test_cloud.sh` check fails.
- Mocked `terraform test` (scratch harness `/tmp/cd-tfcheck2`, outside the repo): new run `db_sslmode_require` decodes both container definitions at plan time (computed RDS, secret and broker values overridden in the run) and finds `DB_SSLMODE = require`; 12 passed. With the billing entry removed it fails. A mocked `apply` run was tried first and failed with "Provider produced inconsistent final plan", so the plan-time form was used. `fmt -check` clean, `validate` passes.
- Live on local Docker with the real app images and libpq, against two `postgres:17-alpine` containers (one with `ssl=on` and a throwaway self-signed certificate, one plaintext; all named `cd-t17-*`, no host ports):
  - inventory-app, `DB_SSLMODE` unset, TLS server: `/ready` 200; `pg_stat_ssl` shows both pooled sessions `ssl=true TLSv1.3`.
  - inventory-app and billing-app, unset, plaintext server: "server does not support SSL, but SSL was required"; billing-app exited 1 after its retries.
  - inventory-app, `prefer`, plaintext server: `/ready` 200, `ssl=false` (unchanged local behaviour).
  - inventory-app, `bogus`: warning, falls back to `require` and refuses the plaintext server.
  - billing-app, unset, TLS server: session `ssl=true TLSv1.3`; with `prefer` against the plaintext server, `ssl=false`. Its `/ready` was 503 in both because no broker ran (the T16 consumer check), with the database sessions up.
- `docker compose config` resolves `DB_SSLMODE=prefer` for both apps, with or without the `.env` line, and gives api-gateway none.
- Cleanup: the two app images, the two PostgreSQL containers with their anonymous volumes (`docker rm -v`), the network, the pulled `postgres:17-alpine` image and the scratch folders were removed; image count back to 17. A combined cleanup command that included `docker volume prune` was blocked by the permission check before it ran; it would have touched other projects' unused volumes, so it was replaced by `docker rm -v` on the two containers only.
- `test_cloud.sh` 64 passed, 0 failed (63 plus the new check; same 2 warnings); `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51.
- Not run: against RDS, and on k3d (no kubectl here).

**Sources**
- [PostgreSQL documentation, libpq SSL Support](https://www.postgresql.org/docs/current/libpq-ssl.html): the six sslmode values; `require` protects against eavesdropping but not MITM; `prefer` only encrypts if the server supports it; `require` acts like `verify-ca` only if a root CA file exists.

Pending docs text (read-only, not applied). `docs/AUDIT_GUIDE.md:1497-1503`, the **Say:** paragraph that calls `?sslmode=require` future application work. Replace those seven lines with:

```
**Say:** "Encryption in transit at the data tier is enforced at both ends.
`rds.force_ssl = 1` makes PostgreSQL refuse a plaintext session outright, and both
apps connect with `sslmode=require` (`DB_SSLMODE`, set in the ECS task
definitions), so the client never offers plaintext either. `require` encrypts but
does not verify the server certificate; `verify-full` with the RDS CA bundle is the
next step."
```

## 2026-10-28 20:53 EET: Phase 2 T18, per-app least-privilege database roles instead of the RDS master user

**What**
- `terraform/files/db_role_init.py` (new folder and file): the script the new `db-role-init` init container runs. It connects as the RDS master (`sslmode=require`, 10 connect attempts 3 s apart, `lock_timeout` 30 s, `statement_timeout` 60 s) and does everything in one transaction behind `pg_advisory_xact_lock`. Steps:
  - creates the app role `WITH LOGIN` if missing, then sets its password as a SCRAM-SHA-256 verifier computed client-side (`psycopg2.extensions.encrypt_password`);
  - refuses a same-named role that has privileged attributes or memberships;
  - revokes `CONNECT` on the app database from `PUBLIC`, grants it to the role, and grants `USAGE, CREATE` on schema `public`;
  - hands tables the master owns over to the role (`GRANT role TO CURRENT_USER WITH INHERIT FALSE, SET TRUE`, then `ALTER TABLE ... OWNER TO`);
  - exits 0 or 1.
- `terraform/rds.tf`:
  - `locals.db_app_users` (`inventory_app`, `billing_app`, the same names as `.env.example`);
  - `random_password.inventory_app_db` / `billing_app_db`;
  - secrets `aws_secretsmanager_secret.inventory_app_db` (`<prefix>-inventory-db-app-credentials`) and `billing_app_db` (`<prefix>-billing-db-app-credentials`) with their versions (same KMS key, `recovery_window_in_days = 0`);
  - the master secret comments now say MASTER and who reads them;
  - the role scope comment.
- `terraform/ecs_services.tf`: the inventory-app and billing-app task definitions now hold two containers.
  - The first is a non-essential `db-role-init`: the app's own image, `python3 -c <script>` via `file()`, the master pair and the app pair as `secrets`, logs under the stream prefix `db-role-init`.
  - The second is the app container, with `dependsOn = [{ containerName = "db-role-init", condition = "SUCCESS" }]`. Its `*_DB_USER` / `*_DB_PASSWORD` now come from the `*_app_db` secrets, and its task definition `depends_on` both secret versions. api-gateway is unchanged.
- `terraform/iam.tf`: `ecs_secrets_access` also allows `GetSecretValue` on the two app role secrets, with a comment on who gets which.
- `terraform/variables.tf`: the `db_username` description says the master is used only by `db-role-init`.
- `scripts/test_cloud.sh`: new static check. The 4 app credentials come from the `*_app_db` secrets, none from the master secrets, both app containers wait for `db-role-init`, and the script exists.
- `README.md`:
  - "3 secrets" becomes 5 in the diagram and in the supporting-resources list;
  - the Secrets section rewritten for five secrets and who receives which;
  - a new "Least-privilege database roles" bullet in Data tier;
  - resource counts 136 to 142 `resource` blocks (131 to 135 `aws_*`) on the two count lines;
  - the recorded `test_cloud.sh` result 64 to 65 PASS.
- `tasklist.md`: T18 ticked and crossed out.
- Not changed: `ecs-tasks/inventory-app-task.json` and `billing-app-task.json` still show the master secret ARNs. They are placeholders, and T47 refreshes them from the real exported task definitions after a deploy. No `srcs/` change: the apps still read `*_DB_USER` / `*_DB_PASSWORD`, only the secret behind them changed.

**Why**
T18 (gap 5.4): both apps connected to RDS as the master user, which has `CREATEROLE`, `CREATEDB` and `rds_superuser`, and AWS itself recommends against using it in applications. An init container in each task was chosen over other ways to create the roles:
- the Terraform postgresql provider: RDS is private and there is no bastion;
- a one-off `run-task` in the deploy script: an extra manual step that a redeploy could skip;
- a Lambda: more resources and cost;
- a separate postgres image: Docker Hub and ECR Public pull limits.

The app image already ships psycopg2, so the init container costs nothing and runs on every task start. It needs no code change in the apps. The table handover keeps a stack deployed before this change working.

**Verified**
- `terraform fmt -check` and `terraform validate` clean.
- Mocked `terraform test` (scratch harness `/tmp/cd-tfcheck2`, outside the repo): 13 passed, 0 failed.
  - `db_sslmode_require` now picks containers by name, since index 0 is `db-role-init`.
  - New run `least_privilege_db_roles` (plan, computed RDS, secret, KMS, password and broker values overridden) checks each of these:
    - `db-role-init` comes first and is non-essential;
    - `dependsOn` is `SUCCESS`;
    - the app credentials come from the app role secrets;
    - no long-running container gets a master secret;
    - `db-role-init` gets the master and app pairs and runs the script;
    - the IAM policy covers both new ARNs;
    - the secrets carry `inventory_app` / `billing_app`.
  - Negative check, inventory-app's password pointed back at the master secret on the harness copy: the new run fails ("inventory-app must get the app role's secret") and so does the new `test_cloud.sh` check (3/4, 1 from master). The harness was restored and passes again.
- Live on local Docker, against `postgres:16-alpine` (16.15, the RDS major) with `ssl=on`. The master was an RDS-like `dbadmin LOGIN CREATEROLE CREATEDB` (not a superuser) owning the databases. The script ran from the freshly built app images, all `cd-t18-*`, no host ports.
  - Fresh run: role created, exit 0. Second run: "up to date", exit 0. Attributes all false, 0 memberships, stored password `SCRAM-SHA-256$...`.
  - inventory-app as `inventory_app` with `DB_SSLMODE=require`: connected, `/ready` 200, `movies` owned by `inventory_app`.
  - Handover: billing-app first ran as the master (a pre-T18 stack) and one order was inserted. The script then moved `orders` and `orders_id_seq` from `dbadmin` to `billing_app`. That confirms the PG16 `GRANT ... WITH INHERIT FALSE, SET TRUE` syntax works for a non-superuser master. billing-app then connected as `billing_app` and an insert read back 2 orders.
  - `inventory_app` was refused each of these: `CREATE ROLE`, `CREATE DATABASE`, reading `pg_authid`, `SET ROLE dbadmin`, connecting to `billing_db`, and `billing_app` connecting to `inventory_db`. It can still connect to the default `postgres` database (`PUBLIC` keeps `CONNECT` there), which the README now states.
  - Password rotation, over the network with scram (the first try went through 127.0.0.1, which the image's `pg_hba.conf` trusts, so it proved nothing and was redone): after a re-run with a new password, the new one logs in with `ssl=True` and the old one is refused, twice in a row.
  - Two runs started together on a fresh role: one "created", one "up to date", both exit 0.
  - Refusals, all exit 1:
    - same-named roles with `CREATEDB` or with a membership, created by the master, are refused by the script itself, and no password is set;
    - the same created by the superuser fail earlier at `ALTER ROLE`, because the master holds no ADMIN on them;
    - a missing `APP_DB_PASSWORD` is reported by name.
  - With `log_statement=all`, none of the four app passwords appear in the server log; the logged `ALTER ROLE` lines show only `SCRAM-SHA-256$4096:...`.
  - Cleanup: the PostgreSQL container with its anonymous volume (`docker rm -f -v`), the network, the two test images, the pulled `postgres:16-alpine` and the scratch folders were removed. The image list is back to its 17 tags and no prune was run.
- `test_cloud.sh` (on a scratch copy) 65 passed, 0 failed, same 2 warnings. `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51, including "Secrets Manager (5 secrets)" and `make test-py` with 70 tests passing.
- Not run: against RDS itself (where the master is also in `rds_superuser`), and an ECS task start on Fargate.

**Sources**
- [Amazon ECS API Reference, ContainerDependency](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ContainerDependency.html): `SUCCESS` is `COMPLETE` plus a zero exit status and cannot be set on an essential container; Fargate needs Linux platform version 1.3.0 or later (the services use the default, LATEST).
- [Amazon RDS User Guide, Master user account privileges](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.MasterAccounts.html): the PostgreSQL master gets `CREATE ROLE`, `CREATE DB`, `ALTER <OBJECT> OWNER` and the `RDS_SUPERUSER` role; AWS strongly recommends not using the master user directly in applications.

Pending docs text (read-only, not applied). All in `docs/AUDIT_GUIDE.md`:

1. Line 264, replace `Secrets Manager (3 secrets)` with `Secrets Manager (5 secrets)`.

2. Line 1535, in the per-file block, replace `rds.tf=10` with `rds.tf=16`. The other numbers in that block were already stale before T18 and are left for the docs refresh.

3. Line 2729, replace the `rds.tf` row with:

```
| `rds.tf` | 16 | 2 KMS-backed `aws_db_instance`, `aws_db_parameter_group` (`rds.force_ssl=1`), 4 Secrets Manager secrets + versions (master and app role for each database), 4 random passwords |
```

4. Lines 2472-2475, replace from `AWS the same principle` up to the end of the answer with:

```
> AWS the same principle is enforced differently: the ECS services inject
> `INVENTORY_DB_PASSWORD` and `BILLING_DB_PASSWORD` from Secrets Manager via
> `secrets = [ … ]`, never as plaintext environment values. They are the
> passwords of the apps' own roles (`inventory_app`, `billing_app`); the RDS
> master password reaches only the short-lived `db-role-init` container.
> `manifests/secrets.yaml` contains only `REPLACE_ME_*` placeholders.
```

5. After point 9 (line 487, before "### The security disclosure"), insert:

```
**10. Least-privilege database roles.** The apps do not connect as the RDS master
user. Each task runs a short `db-role-init` container first
(`terraform/files/db_role_init.py`, from the app's own image), which creates or
updates `inventory_app` / `billing_app` with no `SUPERUSER`, `CREATEDB`,
`CREATEROLE` or memberships, revokes `CONNECT` on the app database from `PUBLIC`
and grants it to that role. The app container starts only after it exits 0
(`dependsOn` `SUCCESS`) and receives only its role's secret. The password is sent
as a SCRAM verifier, so it is never in a server log.
```

## 2026-10-28 21:21 EET: Phase 2 T19 and T20, stale budget text fixed and the monthly cost recomputed

**What**
- `terraform/cloudwatch.tf` (T19):
  - The section 5 header comment no longer repeats the old "300 USD (~260 USD steady state)". It points to `var.monthly_budget_limit` as the one place for the default, the estimate and the threshold reasoning.
  - The `EstimatedCharges` alarm comment claimed the description reads "... exceeds $300". It was wrong twice: the default is 450, and the `$` of `${...}` is consumed by the interpolation, so no dollar sign is rendered. The description now ends `${var.monthly_budget_limit} USD` ("... exceeds 450 USD"), and the comment says why.
- `terraform/variables.tf` (T20): the `monthly_budget_limit` description is rewritten.
  - It has a new itemised estimate from list prices, totalling ~$339/month (about $11 a day). Peak with every service at its maximum (3 + 3 + 6 = 12 tasks) is ~$393.
  - It says what changed against ~$313 and why 450 stays the default. The `single_nat_gateway` description now gives the saving as ~$37/month (the gateway plus its Elastic IP).
- `terraform/terraform.tfvars.example`: NAT comment ~$73 for two (with Elastic IPs) and ~$37 for one; the budget comment gives ~$339 steady, ~$393 peak and why 450.
- `README.md`:
  - the cost table, rebuilt with unit prices and 11 lines, plus a paragraph on the method and what changed, and one on why the budget stays at 450;
  - the broker trade-off bullet (~$100 single instance against ~$300 for the cluster);
  - the cost-effectiveness bullets (NAT ~$37, estimate ~$339);
  - the lever table: `single_nat_gateway` ~$37, and the `monthly_budget_limit` default corrected from `300` to `450`.
- `tasklist.md`: T19 and T20 ticked and crossed out.
- Not changed: `progress.md`, the D2/T01 notes in `tasklist.md` and `docs/HANDOFF.md:331-332`, which record figures at the time they were written. `scripts/run-audit-checks.sh:740` ("450 USD, was 300") is still true.

**Why**
- T19: the comments still described a 300 USD budget and a 260 USD steady state, two revisions out of date.
- T20: the estimate had been patched line by line through T01 and T10, and had never been rebuilt from real prices. Rebuilding it from the AWS Price List moved one line down and added four lines that were missing:
  - down: Amazon MQ, $115 to $100, because RabbitMQ storage is billed on the GB actually used, not on a 200 GB volume;
  - added: the two NAT Elastic IPs (~$7);
  - added: Container Insights (~$27; 88 metrics, needed by the billing-app `RunningTaskCount` alarm);
  - added: Secrets Manager (five secrets since T18) and the target-tracking alarms.

  T02 itself changed no price: an internal ALB bills the same hourly rate.
- Budget: 450 stays on purpose. The 80 % ACTUAL notification (360 USD) has to sit above the ~$339 steady state, or it fires every month, which was the original fault of the 15 USD default. The 100 % notification has to sit above the ~$393 peak. 425 would put the 80 % line at 340, on top of the steady state.

**Verified**
- Prices came from the AWS Price List files for us-east-1, downloaded to a scratch folder outside the repo and read with `jq`. The 481 MB EC2 file was streamed through `grep` for the NAT lines and not saved. The scratch folder was deleted afterwards. Line by line, at 730 hours a month:
  - Amazon MQ `mq.m7g.medium` single instance $0.1367/h, so $99.79 (the 3-node cluster is $0.41/h, $299.30); RabbitMQ EBS $0.10 per GB-month used;
  - RDS PostgreSQL `db.t4g.micro` Multi-AZ $0.032/h and Multi-AZ gp3 $0.23/GB-month, so 2 x (23.36 + 4.60) = $55.92;
  - NAT $0.045/h and $0.045/GB, so $65.70; public IPv4 $0.005/h, so $7.30 for the two NAT Elastic IPs;
  - ALB $0.0225/h + $0.008/LCU-h, so $16.43 plus LCUs;
  - Fargate x86 $0.04048 per vCPU-h and $0.004445 per GB-h, so $9.01 per 0.25 vCPU / 0.5 GB task and $54.06 for 6;
  - Container Insights 13 + 3 x 15 + 3 x 10 = 88 metrics at $0.30, so $26.40;
  - smaller items: alarms $0.10, logs $0.50/GB, Secrets Manager $0.40 per secret, KMS $1 per key, Cloud Map $0.10 per resource, the namespace's Route 53 hosted zone $0.50, ECR $0.10/GB-month, Inspector $0.09 per initial scan and $0.01 per rescan, HTTP API $1 per million requests, interface endpoints $0.01/h.
- Totals: steady $338.50, about $11.13 a day or $0.46 an hour; peak $393.16 with 12 tasks. The usage lines (LCUs, NAT data, logs, scans, requests) are estimates for demo traffic, about $8 of the total.
- Mocked `terraform test` (scratch harness `/tmp/cd-tfcheck2`, outside the repo): 14 passed, 0 failed.
  - The new run `budget_threshold_text` checks that the description reads "... exceeds 450 USD" and that the budget and the alarm share 450.
  - Negative check: with the old description restored on the harness copy, the run fails (13 passed, 1 failed). The harness was restored and passes again.
- `terraform fmt -check` and `terraform validate` clean. `test_cloud.sh` (on a scratch copy) 65 passed, 0 failed, 2 warnings. `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51, including the "450 USD" default checks.
- Not verified:
  - whether the target-tracking alarms are billed and how many there are; AWS documents that Application Auto Scaling creates and manages them, and they are counted here as 2 per policy;
  - real spend, which needs a deployment and Cost Explorer.

**Sources**
- [AWS Price List bulk API, us-east-1 offer files](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/index.json) for AmazonMQ, AmazonRDS, AmazonECS, AWSELB, AmazonVPC, AmazonEC2 (NAT lines only), AmazonCloudWatch, AWSSecretsManager, awskms, AmazonApiGateway, AmazonInspectorV2, AmazonECR, AWSCloudMap and AmazonS3, plus the AmazonRoute53 `aws-other` file for hosted zones; publication dates 2026-09-11 to 2026-10-26. All unit prices above come from these files.
- [Amazon CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/): the Container Insights example for ECS on Fargate without enhanced observability. It counts 13 metrics per cluster, 15 per service and 10 per unique task name at $0.30, and says running more tasks does not add metrics. Free tier: 3 dashboards, 10 standard alarms.
- [Amazon ECS Container Insights metrics](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-ECS.html): the metric names and their ClusterName / ServiceName / TaskDefinitionFamily dimensions.
- [Amazon MQ pricing](https://aws.amazon.com/amazon-mq/pricing/): "you pay for the average amount of storage you use per month"; RabbitMQ brokers use EBS; the m7g example bills storage used.
- [Application Auto Scaling, target tracking](https://docs.aws.amazon.com/autoscaling/application/userguide/application-auto-scaling-target-tracking.html) and [How target tracking works](https://docs.aws.amazon.com/autoscaling/application/userguide/target-tracking-scaling-policy-overview.html): Application Auto Scaling creates and manages the alarms. Neither page gives their number or their price.
- [AWS PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/): an endpoint is billed "for each hour that your VPC endpoint remains provisioned in each Availability Zone".

Pending docs text (read-only, not applied). All in `docs/AUDIT_GUIDE.md`. The cost figures there predate T01; the VPC endpoint claims are wrong at this traffic, because five interface endpoints in two AZs cost about what the two NATs and their Elastic IPs do (~$73). Other stale items in the same passages (for example the broker mode at line 2538) are left for the docs refresh.

1. Lines 223-224, replace from `absolute dollars` to the end of line 224 with:

```
absolute dollars, and this architecture has a real floor cost, roughly $339/month
steady state (MQ ~$100 of it; breakdown in `var.monthly_budget_limit`). Cloud wins here because
```

2. Line 389, replace with:

```
2. **`single_nat_gateway` toggle.** Two NAT Gateways cost roughly \$37/month each with their Elastic IPs.
```

3. Lines 1015-1018 (the "Honest weakness" paragraph), replace with:

```
**Honest weakness to concede first:** NAT Gateways and their Elastic IPs are
roughly $73/month of the ~$339 steady state (MQ ~$100 of it), and the design keeps
two of them on purpose. VPC endpoints would not make it cheaper at this traffic:
the private tier would need five interface endpoints (ECR API, ECR Docker,
CloudWatch Logs, Secrets Manager, SSM Messages for ECS Exec) at $0.01 an hour
each in each AZ, about $73/month in two AZs. They are an isolation improvement
for later, not a cost saving, and they do not exist yet.
```

4. Lines 1205-1212 (the **Say:** paragraph after the `450 USD` output), replace with:

```
**Say:** "The line-item estimate is written into the variable's own description, so
the number and its justification cannot drift apart. Steady state is about \$339 a
month: the broker is about \$100 of it, the two NAT Gateways with their Elastic IPs
about \$73, and Container Insights about \$27, which stays on because an alarm reads
it. Two things I deliberately did *not* cheapen: `multi_az = true` on both databases
and one NAT Gateway per AZ, because the rubric grades availability. The broker is
`SINGLE_INSTANCE`, the one place I chose cost over availability; `CLUSTER_MULTI_AZ`
would cost about \$200 a month more. `ecs_use_fargate_spot` would save up to ~70 %
of compute and defaults to `false` for the same reason."
```

5. Line 2265, the **VPC endpoints** row, replace the third cell with:

```
Not a cost saving at this traffic: five interface endpoints in two AZs (~\$73/month) cost about what the two NAT Gateways with their Elastic IPs do. An isolation improvement for later. |
```

6. Lines 2543-2550 (the answer to question 6), replace with:

```
> Because \$15 was wrong. The real steady state for this design is about \$339/month (MQ ~\$100 of it),
> so a \$15 budget fired every single month and taught an auditor nothing: the alarm
> becomes noise and then gets ignored. The line-item breakdown is written into
> `var.monthly_budget_limit`'s own description so the number and its justification
> cannot drift apart, and there is a `validation` block refusing anything below 50.
> With 450, the 80 % ACTUAL notification fires at \$360, just above the steady state,
> as a genuine early warning, and the 100 % FORECASTED notification sits above the
> ~\$393 peak with every service at its maximum. 425 would put the 80 % line on top
> of the steady state.
```

7. Line 2696, replace with:

```
| No VPC endpoints | Not a cost gap at this traffic: five interface endpoints in two AZs (~\$73/month) cost about what the two NAT Gateways with their Elastic IPs do. An isolation improvement for later. |
```

## 2026-10-28 22:07 EET: README note, the shared AWS account and one project at a time

**What**
- `README.md`:
  - new subsection "Shared AWS account: one project at a time" under Prerequisites, after the path B table. It says this project shares the AWS account and `us-east-1` with `code-keeper`, that the two must never be deployed, tested or audited at the same time, and why:
    - the regional Inspector and API Gateway account settings this stack manages;
    - the Elastic IP and VPC quotas;
    - one bill and the account-wide budget and `EstimatedCharges` alarm;
    - an administrator IAM user, so separation rests on the Terraform state, the `cloud-design-prod-*` names and the `Project` tag.

    It also gives the `export AWS_PROFILE=cloud-design` / `aws sts get-caller-identity` check, and the state found on 2026-10-28.
  - Path B step 1 now exports `AWS_PROFILE=cloud-design` and points to that subsection.

**Why**
The user asked for the README to say that the two projects should not be tested at the same time. `code-keeper` will not be redeployed around the audit, so the region stays `us-east-1`. The account ID and the IAM user names are left out of the README on purpose.

**Verified**
- No em or en dashes in the added lines, and neither the account ID nor an IAM user name appears in them.
- `test_cloud.sh` (scratch copy) 65 passed, 0 failed. `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51.
- The facts in the note come from read-only AWS CLI calls earlier in this session, under the `cloud-design` profile. They found: both profiles in the same account and region; Inspector disabled; no API Gateway CloudWatch role set; 2 of 5 Elastic IPs used, by `code-keeper`'s two stopped EC2 instances; an existing 50 USD budget; no active ECS clusters, NAT gateways, load balancers, RDS instances or MQ brokers.

**Sources**
- None beyond the AWS account itself: the facts come from the read-only AWS CLI checks listed under Verified.

## 2026-10-28 22:43 EET: T21 live AWS demo script, scripts/aws-demo.sh

**What**
- `scripts/aws-demo.sh` (new, executable): the live audit demo against the deployed ECS stack, one section per question.
  - Sections:
    - `verify` (V1, V2);
    - `lb` and `lb-split` (V3);
    - `auth` (S2, S3);
    - `movies` (F1, F2);
    - `billing` (B1, B2);
    - `load` and `scaling` (O1, O2);
    - `security` (S1);
    - `all`.
  - `--pause` waits for Enter before each command, and `--help` prints the header.
  - Every `aws` and `curl` command is printed before it runs. Its real output follows, then a `[PASS]` / `[FAIL]` / `[WARN]` / `[SKIP]` line per check. The exit code is 1 if a check failed and 2 on bad usage.
  - Guards:
    - it stops unless `AWS_PROFILE` equals `DEMO_PROFILE` (default `cloud-design`), because the account is shared;
    - it stops unless `sts get-caller-identity` returns the account in the Terraform outputs;
    - it stops if `terraform/` has no outputs.
  - Everything comes from `terraform output -json`, including the region, read from the API Gateway URL.
  - The Cognito ID token comes from the README recipe (client secret, `SECRET_HASH`, `USER_PASSWORD_AUTH`). The token, the demo password, the client secret and the hash are masked as `$TOKEN`, `$PASSWORD`, `$SECRET` and `$SECRET_HASH` in everything printed. An argument that carries one of them is shown in double quotes, so a pasted copy still expands.
  - `lb` marks its requests with `?lbdemo=<run id>` and counts them per target from field 5 of the ALB access logs in S3. `lb-split` repeats only that count, for logs that arrive later.
  - `load` is a stdlib Python load generator (threads, time based, `LOAD_DURATION` default 300 s, `LOAD_CONCURRENCY` default 32). It shows the scalable targets, the policies and their `TargetTracking-*` CloudWatch alarms, then the scaling activities, the CPU and the desired counts before and after.
  - `billing` only reads for now: the service and scaling state, `MessageCount` and the stored orders. The drill is T22.
- `README.md`:
  - Path B gets a step 6, `scripts/aws-demo.sh all`.
  - New subsection "Live AWS demo (`scripts/aws-demo.sh`)" after Path B, with usage, a section table and what changes state.
  - "Deployment verification" points to `scripts/aws-demo.sh verify lb security`.
  - New row in "Documentation and audit tooling".
- `tasklist.md`: T21 ticked and crossed out.

**Why**
The user asked to move on to T21. The script sits next to `deploy.sh` and follows its style: a header block, `set -uo pipefail`, the identity check first. It also prints each command, because the rubric asks the auditor to see the real commands.

Decisions made along the way:
- Per-task request counts come from the ALB access logs. The gateway runs Waitress with no access log, so the ECS log streams cannot show them.
- The scale-out and scale-in notes point to the live target-tracking alarms instead of quoting minutes, because the AWS docs do not publish fixed datapoint counts for those alarms.
- The `billing` SKIP line, which the auditor sees, does not mention the task list.

**Verified**
- `bash -n` clean. ShellCheck 0.11.0, from the `shellcheck-py` package in a throwaway virtualenv under `/tmp` (outside the repo), is clean. The one file-wide `SC2016` disable is commented: it covers the literal placeholders, the JMESPath backticks and the jq variables.
- No live stack exists, so every section ran against stub `aws`, `terraform` and `curl` commands in `/tmp/cd-demo-stub`. The stubs return the post-`--query` shapes.
  - `verify lb auth movies billing security`: PASS=56 FAIL=0 WARN=0 SKIP=1 (the billing drill).
  - `load` against a local HTTP server: 3945 of 3945 requests answered 200, and the scale-out was detected.
  - Expected failures were reported correctly:
    - wrong profile, other account, no outputs, bad section, bad number and `--pause` with no terminal each stop with a message;
    - without a demo Cognito user, the authenticated checks are skipped and the note is printed once;
    - with no ALB logs yet, the split prints a WARN;
    - when the load host cannot be reached, the load step reports a FAIL and keeps running.
  - No masked value appeared in any run's output.
- Every Terraform output, resource name, log group, route table tag, parameter group setting and S3 log prefix the script uses was checked against `terraform/*.tf`.
- Scratch copy:
  - `test_cloud.sh`: 66 passed, 0 failed, 2 warnings (65 before; the new check is `bash -n clean: aws-demo.sh`).
  - `run-audit-checks.sh --static`: PASS=163 FAIL=0 INVALID=8 NOTES=51, with 8 files in `scripts/`.
- `make test-py`: 25 + 45 tests OK.
- No em or en dashes in the script or in the added README lines.

**Sources**
- [Access logs for your Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-access-logs.html): one file per node every 5 minutes, the S3 key layout, field 5 `target:port`.
- [How target tracking scaling for Application Auto Scaling works](https://docs.aws.amazon.com/autoscaling/application/userguide/target-tracking-scaling-policy-overview.html): Application Auto Scaling creates and manages the alarms, cooldown behaviour. No fixed datapoint counts are given.
- [AWS re:Post: ECS Fargate service auto scaling not working properly](https://www.repost.aws/it/questions/QUVoLPVCU5QamquwCMrFMOzw/aws-ecs-uses-fargate-service-auto-scaling-which-is-not-working-properly): the `TargetTracking-service/<cluster>/<service>-AlarmHigh-<id>` / `-AlarmLow-` alarm names used in `--alarm-name-prefix`.
- [shellcheck-py on PyPI](https://pypi.org/project/shellcheck-py/): the ShellCheck binary used for the lint run.

**Next**
- T22 fills in the `billing` drill: suspend scaling or set min 0, scale `billing-app` to 0, POST, show `MessageCount`, scale back, show the order and the logs, restore scaling.

## 2026-10-28 23:20 EET: T22 billing outage drill on AWS in scripts/aws-demo.sh

**What**
- `scripts/aws-demo.sh`: the `billing` section is now the B1/B2 drill. It used to only read.
  - Preconditions, checked before anything changes: a Cognito token, billing-app steady (running equals desired, rollout COMPLETED), and a readable scalable target. Otherwise the section skips or fails without touching the stack.
  - Steps:
    1. Read billing-app's desired count, min, max and suspended state.
    2. `register-scalable-target --min-capacity 0` with scale-in, scale-out and scheduled scaling suspended.
    3. `update-service --desired-count 0`, then poll until 0 tasks run, and show `GET /api/billing/orders` answering 503.
    4. POST an order through API Gateway with `user_id` set to the epoch seconds (B1, expects 200).
    5. Poll the broker's `MessageCount` from the POST's minute until it shows the message.
    6. `update-service` back to the desired count from step 1, then poll until it runs.
    7. Poll `GET /api/billing/orders` until the order is listed (B2), show its lines with `aws logs tail --filter-pattern`, poll `MessageCount` back to 0, and show the `consumers-below-min` alarm history.
    8. Register the original min, max and suspended state again, and compare them with step 1.
  - New `DRILL_WAIT` (default 420 s) caps each poll, and it is validated like the other numbers.
  - New `drill_restore` and an `on_exit` EXIT trap, with INT and TERM traps that exit 130 and 143. If the script stops between steps 2 and 8, they put the desired count and the scalable target back, printing each command.
  - The header, WHAT CHANGES STATE and ENVIRONMENT text are updated.
- `README.md`:
  - the `billing` row in the "Live AWS demo" table;
  - the paragraph on what changes state;
  - new subsection "Resilience drill on AWS" after the local drill: the eight steps, the trap, the alarm that fires, and why the order, not the metric, decides B2.
- `tasklist.md`: T22 ticked and crossed out.

**Why**
The user asked to start T22.

The order of the steps comes from the RegisterScalableTarget API reference: an update call moves the current capacity into [min, max] at once. So the minimum is lowered to 0 while the tasks still run, scaling is suspended, and only then is the service scaled to 0. The minimum is restored after the tasks run again.

Only `consumers-below-min` is expected to fire. The backlog alarm needs more than 100 messages for 5 minutes, so the claim in `progress.md` line 281 that both fire in the B1 drill does not hold. `progress.md` was left unchanged.

**Verified**
- `bash -n` and ShellCheck 0.11.0 (the `/tmp` virtualenv from T21) are clean.
- No live stack exists, so the drill ran against the extended stubs in `/tmp/cd-demo-stub`. They now keep billing-app's desired count, scalable target, posted order, queue metric and alarm history as state.
  - Normal run: PASS=11 FAIL=0, with the scalable target back at min 2, max 6, nothing suspended.
  - A restart that never comes up: two FAILs, the auto scaling still restored, exit 1.
  - SIGINT during the queue wait: the trap printed `[RESTORE]` and set the desired count back to 2 and the target to min 2, max 6, all suspensions false. Exit 130.
  - No demo Cognito user, or billing-app not steady: skip or fail, with no `update-service` or `register-scalable-target` call at all.
  - `DRILL_WAIT=abc` is rejected with exit 2.
  - No masked value appeared in any drill output.
- Regression: `verify lb auth movies billing security` against the stubs gives PASS=65 FAIL=0 WARN=0 SKIP=0.
- Scratch copy: `test_cloud.sh` 66 checks passed, 2 warnings. `run-audit-checks.sh --static` PASS=163 FAIL=0 INVALID=8 NOTES=51.
- No em or en dashes in the script or in the added README lines.

**Sources**
- [RegisterScalableTarget, Application Auto Scaling API Reference](https://docs.aws.amazon.com/autoscaling/application/APIReference/API_RegisterScalableTarget.html): an update moves the current capacity into [min, max]; omitted parameters are not changed; the minimum for ECS services may be 0.
- [Suspend and resume scaling for Application Auto Scaling](https://docs.aws.amazon.com/autoscaling/application/userguide/application-auto-scaling-suspend-resume-scaling.html): the three suspended-state flags and the `register-scalable-target --suspended-state` command.

**Next**
- T37 [AWS] runs this drill on the live stack and captures the B1/B2 evidence.
