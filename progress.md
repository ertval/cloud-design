# Cloud-Design: what remains to meet the audit questions

Written 2026-10-27, against commit `d63d1fa` on `main`.

Sources compared:

- `docs/cloud-design-instructions.md` (the brief)
- `docs/cloud-design-questions.md` (the audit questions, the success criteria)
- Every tracked file in the repository: `README.md`, `terraform/`, `srcs/`, `manifests/`, `ecs-tasks/`, `scripts/`, `docker-compose.yml`, `Makefile` and `docs/`

What was actually run while writing this: `terraform init -backend=false`, `terraform validate` and `terraform fmt -check` on a **temporary copy** of `terraform/` (Terraform v1.16.7, AWS provider 5.100.0). All three pass. No AWS API call was made, no container was started and nothing in the project was changed apart from this file.

---

## 1. Summary

The repository is well built for a **local** demonstration: six Dockerfiles, a working `docker compose` stack, Kubernetes manifests, 19 Terraform files and a detailed README. The audit questions, though, are about a **live AWS deployment**, and that part has never been done. `README.md` says so itself: no `terraform apply` was ever run and no AWS resource was ever inspected.

The new questions file adds checks that the old `docs/audit.md` did not have, and the project's documents and audit scripts were built against the old file. All the new checks require a live AWS stack:

- show `aws cli` plus ECS commands (or `kubectl`) to verify the deployment
- create a movie with POST and read it back with GET, **through API Gateway**
- stop the billing service, send a billing request through API Gateway, restart the service and show the order was processed
- show that a request without valid credentials is rejected, and demonstrate the Cognito configuration
- show "restricting database access to the VPC"

`terraform validate` passes, but reading the code against AWS's documented behaviour shows **several defects that would break `terraform apply` or the live demo**. They have to be fixed before deploying (section 3).

So the work that remains, in order:

1. Fix the apply and runtime blockers (section 3).
2. Deploy to AWS and capture live evidence for every question (section 4).
3. Close the design gaps an auditor will probe (section 5).
4. Bring the README, the audit scripts and the role-play guide in line with the new questions and with what is really deployed (section 6).
5. Rehearse the role-play (section 7).
6. Tear everything down after the audit (section 4.10).

---

## 2. Status per audit question

Status legend: **Ready** = can be shown today. **Partial** = present but incomplete or inaccurate. **Blocked** = depends on a defect in section 3. **Not done** = needs work that does not exist yet.

| # | Question (from `cloud-design-questions.md`) | Status | What is missing |
|---|---|---|---|
| G1 | Required files present (README, source, deploy scripts, IaC, container and orchestration config) | Ready | Minor: `ecs-tasks/*.json` are placeholders, including task definitions for databases and the broker that are never deployed (section 6.4) |
| R1 | Role-play: answer all 14 questions correctly | Partial | `docs/AUDIT_GUIDE.md` has answers, but several are now wrong (broker mode, API Gateway to ALB hop, cost figures) and none cover the live AWS demo (section 7) |
| R2-R4 | Understanding, communication, critical evaluation | Partial | Rehearsal, after the fixes, so the answers match what is deployed |
| A1 | Scalability | Partial | Policies exist in Terraform; never exercised on AWS (section 4.8) |
| A2 | Availability, fault tolerance | Partial | `api-gateway` and `inventory-app` run 1 task, so "one AZ loss halves capacity" is false; the broker mode is invalid (sections 3.1 and 5.1) |
| A3 | Security: encryption, VPC, secure endpoints, Cognito | Blocked | Sections 3.2, 3.3 and 3.6 |
| A4 | Cost-effectiveness | Partial | Cost numbers change once the broker mode is fixed; no measured AWS spend (section 5.6) |
| A5 | Simplicity | Partial | Internet-facing ALB with its own Cognito action plus API Gateway in front is two auth layers and two public entry points (section 5.2) |
| A6 | Architecture and choice of services match the requirements | Partial | Depends on A1 to A5 |
| A7 | Cost-effective architecture | Partial | As A4 |
| D1 | README has prerequisites, setup, configuration, usage | Partial | Setup and usage commands for AWS contain errors that fail when run (section 6.1) |
| D2 | README clear and complete, with diagrams | Partial | Diagrams exist; several statements contradict the code or each other (section 6.1) |
| V1 | Show proper use of `aws cli` + ECS commands (+ `docker ps` if applicable) to verify the deployment | Not done | Needs a live stack (section 4) |
| V2 | All microservices running in the cloud, no errors | Not done | Blocked by section 3, then needs a live stack |
| V3 | Load balancing configured and distributing traffic | Not done | Only one `api-gateway` task, so the ALB has one target to distribute to (section 5.1); needs live proof |
| V4 | Services communicate securely (authentication and encryption) | Blocked | API Gateway to ALB hop does not work as written (section 3.2) |
| F1 | POST a movie through API Gateway, success code | Blocked | Sections 3.2, 3.6, then live demo |
| F2 | GET the movies back through API Gateway | Blocked | Same as F1 |
| B1 | Billing service stopped, billing request through API Gateway still succeeds | Not done | No AWS procedure exists; the autoscaler (min 2) can restart the service during the drill (section 4.7) |
| B2 | After restart, the queued request is processed | Not done | Same as B1 |
| T1 | Terraform used effectively (`terraform plan` / `apply` shown) | Blocked | Section 3.1 and 3.4 make apply fail or the next plan fail |
| T2 | Infrastructure follows the design and requirements | Partial | Depends on sections 3 and 5 |
| C1 | Dockerfiles optimised | Ready | Multi-stage, Alpine, non-root, wheels only. Re-measure sizes and build times on this machine (section 6.1) |
| C2 | Orchestration (ECS task definitions) configured correctly | Blocked | Image tag mismatch (section 3.5); placeholder `ecs-tasks/` (section 6.4) |
| M1 | Monitoring and logging dashboards give useful insight | Partial | One dashboard widget can never show data; no log widget; no alarm for the queue consumer (section 5.3) |
| O1 | Auto-scaling policies configured correctly | Partial | Configured, never triggered on AWS (section 4.8) |
| O2 | Efficient under different load scenarios | Not done | Load tests exist only for the local stack |
| S1 | HTTPS, secured endpoints, DB access restricted to the VPC, vulnerability scanning | Partial | Mostly in Terraform; needs live proof (section 4.9) |
| S2 | Request without valid credentials is rejected at API Gateway | Not done | Needs a live stack. This is the one item the audit script already marks INVALID |
| S3 | Demonstrate the managed authentication (Cognito) protecting API Gateway | Blocked | The documented login command fails (section 3.6) |
| X1 | Bonus | Partial | Several bonus items exist; FaaS and CDN do not (section 8) |

---

## 3. Blockers to fix before the first `terraform apply`

Each of these was found by reading the code. Items 3.1 to 3.6 were checked against AWS documentation; the exact failure message can only be confirmed by a real apply.

### 3.1 Amazon MQ: `ACTIVE_STANDBY_MULTI_AZ` is not a valid mode for RabbitMQ

- **Where:** `terraform/amazon_mq.tf:71` (`deployment_mode = "ACTIVE_STANDBY_MULTI_AZ"`), repeated in `README.md`, `terraform.tfvars.example`, the cost table and `docs/AUDIT_GUIDE.md`.
- **Problem:** Amazon MQ for RabbitMQ supports only a single-instance broker or a 3-node cluster. Active/standby is an ActiveMQ mode. `CreateBroker` will reject the request, so `terraform apply` fails on the broker and everything that depends on it (both ECS task definitions that read `RABBITMQ_HOST`, the autoscaling policy, the dashboard).
- **Fix (recommended):** `deployment_mode = "CLUSTER_MULTI_AZ"`. This keeps the "Multi-AZ broker" claim true. `mq.m7g.medium` is listed for cluster deployments. A cluster runs **three** broker nodes, so recompute the cost line and the budget. Check at plan/apply time whether two private DB subnets are accepted for a cluster; if not, add a third subnet in a third AZ.
- **Cheaper alternative:** `SINGLE_INSTANCE`. Then the README must stop claiming a Multi-AZ broker and must explain the trade-off (a broker outage makes `POST /api/billing` return 503 until it recovers; queued messages survive on EBS).
- **Also update:** the README sentence "`CLUSTER_MULTI_AZ` needs three AZs and the design has two" and the matching comment in `amazon_mq.tf:70`.

### 3.2 API Gateway sends plain HTTP to the ALB's HTTPS listener

- **Where:** `terraform/api_gateway.tf:119-128`, integration with `integration_uri = aws_lb_listener.https.arn` and no `tls_config` block.
- **Problem:** the API Gateway v2 reference says: "If you specify a TLS configuration, private integration traffic uses the HTTPS protocol." With no `tls_config`, API Gateway speaks HTTP to port 443, and the ALB answers with an error. Every route, including `/health`, `/api/movies` and `/api/billing`, would fail. This alone blocks F1, F2, B1, B2, S2 and S3.
- **The repo also contradicts itself here:** `alb.tf:21-24` says the VPC Link hop does not validate the certificate, while `README.md:898` and `terraform.tfvars.example` say it does.
- **Fix, option A (best, needs a domain):** register or use a domain in Route 53, set `enable_acm_certificate = true`, `alb_domain_name`, `alb_hosted_zone_id`, and add `tls_config { server_name_to_verify = var.alb_domain_name }` to the integration. HTTP APIs have no "skip verification" option, so the self-signed path cannot work over HTTPS.
- **Fix, option B (no domain):** add an HTTP listener that only the VPC Link security group can reach, point the integration at it, and document that this hop is plaintext inside the VPC while the public edge is HTTPS (API Gateway's own certificate). Combine with 5.2 (make the ALB internal).
- Whichever you choose, write the decision and its trade-off in the README Security section. It is a likely auditor question.

### 3.3 The ALB's `authenticate-cognito` action uses an app client with no secret

- **Where:** `terraform/alb.tf:264-277` uses `aws_cognito_user_pool_client.main`, which has `generate_secret = false` (`terraform/cognito.tf:111`).
- **Problem:** ALB Cognito authentication requires an app client **with** a client secret (AWS knowledge-centre guidance; a secret cannot be added to an existing client). Expect the HTTPS listener create to fail, or the action to fail at runtime. The comment in `alb.tf:239-242` states the opposite.
- **Fix:** either create a dedicated confidential client for the ALB (`generate_secret = true`, `allowed_oauth_flows = ["code"]`, `openid` scope, callback `https://<alb-host>/oauth2/idpresponse`), or remove the ALB Cognito action entirely by making the ALB internal (section 5.2). The second option is simpler and removes the "any ENI in the VPC can reach :443" residual risk the README documents.

### 3.4 The S3 bucket policy denies every request to everyone

- **Where:** `terraform/storage.tf:143-157`, statement `DenyInsecureTransport`.
- **Problem:** it denies `s3:*` on the bucket and its objects for principal `*` with **no condition**. The intended `aws:SecureTransport = false` condition is missing. Once the policy is applied, Terraform itself loses access to the bucket, so the next `terraform plan` (refresh) and `terraform destroy` fail with AccessDenied. Only the account root user can delete such a policy.
- **Fix:** add
  ```hcl
  condition {
    test     = "Bool"
    variable = "aws:SecureTransport"
    values   = ["false"]
  }
  ```
  to that statement. Then give the bucket a real job (section 5.3, ALB access logs), because "nothing writes to it" is a weak answer to "storage services (S3 or similar)".

### 3.5 Images are pushed as `:local` but ECS pulls `:latest`

- **Where:** `scripts/build_push.sh:49` (`TAG="${TAG:-local}"`) and `:167` (pushes `<repo>:${TAG}`); `terraform/ecs_services.tf:21` (task definitions use `:latest`).
- **Problem:** `PUSH=1 bash scripts/build_push.sh`, the command the README gives (`README.md:772`), pushes `cloud-design/<app>:local`. ECS looks for `:latest`, finds nothing, and every task fails with `CannotPullContainerError`.
- **Fix:** push both tags (or `:latest` when `PUSH=1`), or better, push an immutable tag (git short SHA) and pass it to Terraform as a variable so each deploy creates a new task definition revision.
- **Related README errors:** `README.md:778` re-runs `terraform apply tfplan` after the push. A saved plan cannot be applied twice ("Saved plan is stale"), and even a fresh apply would not redeploy because the task definition does not change. Replace with `aws ecs update-service --cluster <c> --service <s> --force-new-deployment` for each service, then `aws ecs wait services-stable`.
- **Ordering:** the ECR repositories are created by Terraform, so either create them first (`terraform apply -target=aws_ecr_repository.app`), push, then apply the rest, or accept failing tasks until the push and then force a new deployment.

### 3.6 The documented Cognito login command cannot work

- **Where:** `README.md:946-961`.
- **Problems:**
  1. `aws cognito-idp initiate-auth` has no `--secret` option. For a client with a secret, `SECRET_HASH` must be passed inside `--auth-parameters`.
  2. The generated demo password may contain `=` (`terraform/cognito.tf:19`, `override_special = "!#$%&*()-_=+"`), which breaks the `KEY=value,KEY=value` shorthand of `--auth-parameters`.
- **Fix:** compute the hash and use the JSON form:
  ```bash
  SECRET_HASH=$(printf '%s' "${EMAIL}${CID}" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64)
  aws cognito-idp initiate-auth --client-id "$CID" --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "{\"USERNAME\":\"$EMAIL\",\"PASSWORD\":\"$PASS\",\"SECRET_HASH\":\"$SECRET_HASH\"}" \
    --query AuthenticationResult.IdToken --output text
  ```
  Or make the demo client public (`generate_secret = false`) and drop the hash. Also remove `=` and `,` from `override_special`.

### 3.7 `scripts/deploy.sh` cannot complete an AWS deployment

- **Where:** `scripts/deploy.sh:155-164` and `:213-269`.
- **Problems:** it builds and pushes images **before** Terraform has created the ECR repositories; after `terraform apply` it requires `kubectl` and a reachable Kubernetes cluster and applies `manifests/`, but this project deploys ECS, not EKS (and `kubectl` is not installed on this machine). On AWS it either dies at the kubectl step or applies the manifests to whatever local cluster is the current context.
- **Fix:** make the AWS path: `terraform init/validate/plan/apply` (ECR first), `build_push.sh --push` with the right tag, `aws ecs update-service --force-new-deployment` per service, `aws ecs wait services-stable`, then print the key outputs. Keep the manifests path in `deploy-k3d.sh` only.

### 3.8 `scripts/destroy.sh --kms` schedules deletion of every KMS key in the account

- **Where:** `scripts/destroy.sh:225-240` loops over `aws kms list-keys` with no filter.
- **Problem:** with `--kms` it schedules deletion for **all** keys in the region, including keys that belong to other projects in the same account (there is already an unrelated `code-keeper` profile configured on this machine). `terraform destroy` already schedules deletion of this project's own key, so the flag adds risk and no value. `README.md:1511` also says `--kms` "cancels that window", which is wrong.
- **Fix:** remove the loop, or limit it to the key ID from `terraform output` / the project tag. Fix the README sentence.

---

## 4. Deploy to AWS and capture the live evidence

The auditor must **see** these commands run. Put the exact commands in a script (for example `scripts/aws-demo.sh` or `make aws-*` targets) so the demo is repeatable, and paste real output into the README afterwards.

### 4.1 Prerequisites on this machine

- [ ] AWS credentials for **this** project (a dedicated profile, e.g. `export AWS_PROFILE=cloud-design`). Only a `code-keeper` profile exists today; do not deploy into an unrelated account by accident.
- [ ] In the Billing console, enable "Receive CloudWatch billing alerts", otherwise the `EstimatedCharges` alarm never has data. That metric exists only in `us-east-1`.
- [ ] Install the Session Manager plugin if you want to demo `aws ecs execute-command` (`enable_execute_command = true` is already set).
- [ ] Optional, for the Kubernetes bonus path only: `kubectl` and `k3d` (neither is installed here).
- [ ] Decide the TLS option from 3.2 (domain or not) before the first apply.
- [ ] Copy `terraform/terraform.tfvars.example` to `terraform.tfvars` and set at least `alarm_email` (then confirm the SNS email) and `allowed_origins`.

### 4.2 Provision

- [ ] `terraform -chdir=terraform init && terraform -chdir=terraform plan -out=tfplan && terraform -chdir=terraform apply tfplan`
- [ ] Push the three app images with the tag ECS expects (3.5), force a new deployment, `aws ecs wait services-stable`.
- [ ] Run `terraform plan` again and show **"No changes"**. This is the strongest single proof for T1 (Terraform manages the whole stack without drift).

### 4.3 Verify the deployment (V1, V2)

Commands to rehearse and show:

```bash
aws sts get-caller-identity
aws ecs list-services --cluster <cluster>
aws ecs describe-services --cluster <cluster> --services <svc...> \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount,status:status}'
aws ecs list-tasks --cluster <cluster> --service-name <svc>
aws ecs describe-tasks --cluster <cluster> --tasks <arn...> --query 'tasks[].{az:availabilityZone,health:healthStatus,last:lastStatus}'
aws elbv2 describe-target-health --target-group-arn <apigw-tg-arn>
aws logs tail /aws/microservices/cloud-design-prod/billing-app --since 10m
aws rds describe-db-instances --query 'DBInstances[].{id:DBInstanceIdentifier,multiAZ:MultiAZ,public:PubliclyAccessible,encrypted:StorageEncrypted}'
aws mq describe-broker --broker-id <id> --query '{mode:DeploymentMode,public:PubliclyAccessible,state:BrokerState}'
```

- [ ] Explain why `docker ps` does not apply on Fargate (no host to log in to) and show `docker ps` on the local compose stack instead, or `aws ecs execute-command` into a task.

### 4.4 Load balancing (V3)

- [ ] Run at least 2 `api-gateway` tasks (section 5.1).
- [ ] Show `describe-target-health` with two healthy targets in two AZs.
- [ ] Prove distribution: send N requests, then show the per-target split (ALB access logs in S3, or CloudWatch `RequestCountPerTarget`, or one log stream per task in `aws logs`).

### 4.5 Authentication (S2, S3)

- [ ] `curl -i "$API/api/movies"` with no token: show **401**.
- [ ] Same call with a garbage token: show **401**.
- [ ] Get a real token (3.6), call again: show **200**.
- [ ] Show the configuration: `aws apigatewayv2 get-authorizers --api-id <id>`, `aws apigatewayv2 get-routes --api-id <id>` (authorization type JWT on every `/api/*` route), `aws cognito-idp describe-user-pool --user-pool-id <id>`.
- [ ] Be ready to explain why `GET /health` answers without a token.

### 4.6 API functionality through API Gateway (F1, F2)

- [ ] `POST $API/api/movies` with a JWT and a JSON body: show the 200 and the returned `id`.
- [ ] `GET $API/api/movies`: show the created movie in the response.
- [ ] Note: the README example sends `"year":2026`, which the app ignores (the model only has `title` and `description`). Use a body with `description` so the response visibly contains what was sent.

### 4.7 Billing resilience through API Gateway (B1, B2)

No AWS procedure exists yet. The local drill (`make consumer-drain`) does not count for "the cloud environment". Write and rehearse this:

1. [ ] Stop the autoscaler from restarting the consumer during the drill. `billing-app` has `min_capacity = 2`, so either register the scalable target with `--min-capacity 0`, or use `--suspended-state DynamicScalingInSuspended=true,DynamicScalingOutSuspended=true,ScheduledScalingSuspended=true`.
2. [ ] `aws ecs update-service --cluster <c> --service <billing> --desired-count 0` and `aws ecs wait services-stable`; show `runningCount: 0`.
3. [ ] `POST $API/api/billing` with a JWT and a valid payload: show the 200.
4. [ ] Show the message is waiting: CloudWatch `AWS/AmazonMQ MessageCount` (allow a minute or two of metric delay).
5. [ ] Set desired count back to 2, wait for stable, and show `GET $API/api/billing/orders` containing the new order, plus the "Successfully processed and recorded order" line in `aws logs tail`.
6. [ ] Restore the scalable target (min 2, scaling resumed).

### 4.8 Auto-scaling and load (O1, O2, A1)

- [ ] Run a load test against API Gateway with a valid token (for example `hey`, `k6`, or the Python script in the README pointed at `$API`), long enough to push `api-gateway` CPU over 60 %.
- [ ] Show `aws application-autoscaling describe-scaling-activities --service-namespace ecs`, the service event log, and the dashboard CPU widget during scale-out and later scale-in.
- [ ] For `billing-app`, show scale-out on queue depth: publish more than 50 messages with the consumer slowed or stopped, then let it scale.
- [ ] Record the measured numbers (requests per second, p95, task count over time) in the README. Today only local numbers exist.

### 4.9 Security evidence (S1)

- [ ] HTTPS only: `curl -I http://<alb>` shows the 301; TLS policy from `aws elbv2 describe-listeners`.
- [ ] Databases only reachable inside the VPC: `PubliclyAccessible: false`, the DB security group rule with the app SG as the only source, and the DB route table with no default route (`aws ec2 describe-route-tables`). A failed `psql` from your laptop is a good live proof.
- [ ] Vulnerability scanning: `aws inspector2 list-findings` (or `aws ecr describe-image-scan-findings`) for the pushed images, and what you would do about any CRITICAL/HIGH finding.
- [ ] Encryption at rest: `StorageEncrypted: true` and the KMS key with rotation on.

### 4.10 Teardown and cost

- [ ] At ~$410 per month the stack costs roughly $0.56 per hour, and more once the broker runs as a 3-node cluster. Deploy shortly before the audit and destroy right after.
- [ ] After `terraform destroy`, run the "verify nothing is left billing" commands the destroy script prints, and check that the S3 bucket and NAT gateways are gone.

---

## 5. Design gaps the auditor will probe

### 5.1 Availability and load balancing

- `api-gateway` and `inventory-app` start with `desired_count = 1` (`terraform/ecs_services.tf:224,286`) and `min_capacity = 1` (`terraform/autoscaling.tf:28,58`). One task sits in one AZ, so the README claim "one AZ loss halves capacity rather than removing it" is not true for the request path, and the ALB has nothing to balance across. **Raise both to 2** (about $18 per month for the two extra tasks) and update the cost table.
- `billing-app` keeps `desired_count = 2` without `ignore_changes`, so any `terraform apply` after a scale-out resets it to 2. Either add `ignore_changes = [desired_count]` or be ready to explain the choice.

### 5.2 Edge design: make API Gateway the only public entry (recommended)

Today the ALB is internet-facing (`terraform/alb.tf:147`) with its own Cognito action and two source-IP bypass rules, and API Gateway sits in front of it. That is two public entry points and two auth layers; the README itself lists the residual risk. Making the ALB `internal = true`, reached only through the VPC Link, would:

- remove blocker 3.3 entirely (no ALB Cognito action needed),
- match the brief literally: "securing API endpoints with Amazon API Gateway" and private resources accessible only from the VPC,
- improve the Simplicity score,
- close the "any ENI in the VPC can reach :443" gap.

Combine it with option A or B from 3.2.

### 5.3 Monitoring and logging (M1)

- The dashboard widget "ALB Target Health" (`terraform/cloudwatch.tf:407-408`) queries `UnHealthyHostCount` / `HealthyHostCount` with only the `LoadBalancer` dimension. ALB publishes those metrics per target group, so the widget will stay empty. Add the `TargetGroup` dimension (one line per target group).
- No log widget. Add a CloudWatch Logs Insights widget (errors per service, recent 5xx) so "logging dashboards" is literally true.
- No alarm for the queue consumer. Add one on `billing-app` running task count below 2 and one on `MessageCount` staying high; both would fire during the B1 drill, which makes a good live moment.
- `/health` on `billing-app` stays 200 even when the consumer thread cannot reach the broker, so the task looks healthy while consuming nothing. Consider a consumer heartbeat in `/ready` or a log-based metric.
- Enable ALB access logs into the S3 bucket. It proves load distribution (4.4) and gives the bucket a real purpose. The bucket policy then needs to allow the ELB log delivery principal (and 3.4 must be fixed first).
- Small stale text: `terraform/cloudwatch.tf:443-446` and `:489` still mention a 300 USD budget and a 260 USD steady state.

### 5.4 Secure service-to-service communication (V4)

Prepare an honest answer. Today: TLS at the edge, AMQPS to the broker with certificate verification, `rds.force_ssl = 1` on the databases, security groups between tiers. Plaintext HTTP remains between the ALB and the tasks and between `api-gateway` and `inventory-app`, all inside private subnets. Cheap improvements:

- Append `sslmode=require` to both database URLs (`srcs/inventory-app/app/__init__.py:148`, `srcs/billing-app/app/__init__.py:224`, via `query={"sslmode": "require"}` in `URL.create`). The README already lists this as a gap; it is a two-line change.
- Optional: a dedicated least-privilege database role for each app instead of the RDS master user `dbadmin`.

### 5.5 Smaller items to check at the first apply (lower confidence)

- `service_registries` sets `container_port` while the Cloud Map records are type `A` (`terraform/ecs_services.tf:263-267` and the other two services). If ECS rejects it, drop `container_name`/`container_port` for A records.
- The broker security group opens 15671 for the management console; confirm which port Amazon MQ actually serves the console and management API on for your broker, and adjust or remove the rule.
- Confirm PostgreSQL 16.9 is still offered: `aws rds describe-db-engine-versions --engine postgres --engine-version 16.9`.
- `aws_api_gateway_account` is an account-wide setting; it overwrites whatever the account had before.

### 5.6 Cost (A4, A7)

- Recompute the monthly estimate after 3.1 and 5.1 and update `var.monthly_budget_limit`, the README table and the AUDIT_GUIDE answer together.
- After the deployment has run for a day, show the real spend in Cost Explorer or `aws ce get-cost-and-usage`. A measured number answers "how did you manage cost" far better than an estimate.

---

## 6. Documentation and tooling updates

### 6.1 `README.md` corrections

| Line | Problem | Fix |
|---|---|---|
| throughout | Broker described as `ACTIVE_STANDBY_MULTI_AZ` | Match the mode chosen in 3.1 |
| 407 | "The 18 `.tf` files" | 19 (the header at line 12 is already correct) |
| 772 | `PUSH=1 bash scripts/build_push.sh` pushes `:local` | See 3.5 |
| 778 | Re-applies a consumed `tfplan` | Force a new ECS deployment instead (3.5) |
| 898 | "the API Gateway VPC Link integration validates the chain" | Replace with the real behaviour and your 3.2 decision |
| 946-961 | `--secret` is not an option; shorthand breaks on `=` | See 3.6 |
| 1003 | "18 unit tests (9 + 9)" | 52 (20 + 32), as line 1528 says; re-run to confirm |
| 1207 | `kubectl get hpa, pdb` (space after the comma is invalid) | `kubectl get hpa,pdb -n cloud-design` |
| 1350 | Cost lever table says `monthly_budget_limit` default `300` | 450 (or the new figure from 5.6) |
| 1322, 1333, 1511 | `destroy.sh --kms` described as safe / "cancels that window" | See 3.8 |
| 247-302 | Component names follow the old brief | Add the names used by `cloud-design-instructions.md` (`inventory-db`, `billing-db`, `rabbit-queue`, `api-gateway-app`) and map them to `inventory-database`, `billing-database`, `rabbit-queue`, `api-gateway`. Commit `630f998` renamed `api-gateway-app` to `api-gateway` on purpose, which is fine, but the mapping has to be explicit because the official brief uses the old name |
| 1185-1273, 1518-1599 | "Verified live on this machine, today" and the audit tallies were measured on a different machine (the handoff notes a different home directory) and before the new questions existed | Re-run on this machine and replace the numbers, or reword. Add a new "Verified on AWS" table with the evidence from section 4 |
| all `docs/audit.md` / `docs/readme.md` references | Point at the old rubric and brief, often with line numbers | Point at `docs/cloud-design-questions.md` / `docs/cloud-design-instructions.md` |
| Usage, AWS | No AWS version of the resilience drill, the load test or the 401 test | Add them (sections 4.5 to 4.8) |
| Prerequisites | Missing: Session Manager plugin, billing alerts setting, domain requirement if you choose option A in 3.2 | Add |

### 6.2 Files in `docs/` (read-only for me; you need to apply these)

- `docs/readme.md` and `docs/audit.md` are the old brief and rubric; the new `docs/cloud-design-instructions.md` and `docs/cloud-design-questions.md` are untracked. Decide whether to replace the old pair (then update every reference listed in 6.1 and 6.3) or keep both and say which one is authoritative.
- `docs/AUDIT_GUIDE.md` is built around the 22 old questions. It needs new entries for: proper use of ECS commands (V1), POST and GET through API Gateway (F1, F2), billing resilience on ECS (B1, B2), "restricting database access to the VPC" (S1), the 401 test (S2) and the Cognito demonstration (S3). Answers that change after section 3: the broker mode (Q5, Q9, availability pillar), the edge design (Q5, Q7), the cost figures (Q6).
- `docs/HANDOFF.md` is an internal work log (other sessions, a terminal-pane tool, another machine's paths). Consider removing it from the submission or moving it out of the deliverable.

### 6.3 Audit and test scripts

- `scripts/run-audit-checks.sh`, `scripts/step_by_step_audit.py` and `scripts/test_cloud.sh` are keyed to `docs/audit.md` and its 22 items, all local. Add an AWS mode covering V1 to V4, F1, F2, B1, B2, S2 and S3, so the live demo is one command and every section prints real output.
- `scripts/test_cloud.sh:53-59` fails if `docs/audit.md` is removed; update it if you replace the rubric file.
- `scripts/deploy.sh` and `scripts/destroy.sh`: see 3.7 and 3.8.

### 6.4 `ecs-tasks/`

The six JSON files use placeholder account IDs and hosts, and three of them (`inventory-database`, `billing-database`, `rabbitmq`) describe tasks that are never deployed because RDS and Amazon MQ replace them. Under C2 ("ECS task definitions configured correctly") this invites the question "why do these differ from what runs?". After deploying, replace them with the real definitions exported by `aws ecs describe-task-definition` (secrets are ARNs, so nothing sensitive is exposed), or delete the folder and point to `terraform/ecs_services.tf`.

---

## 7. Role-play preparation

- [ ] Update the prepared answers after sections 3 and 5 (broker mode, edge design, cost, availability numbers).
- [ ] Add short spoken answers for the live sections: what each `aws ecs` command proves, why there is no `docker ps` on Fargate, why the queue keeps orders while the consumer is down, why `/health` is unauthenticated.
- [ ] Prepare the "what would you change" answer with the honest residuals that remain after the fixes (plaintext inside the VPC, single region, local Terraform state with no S3 backend or locking, no CI/CD pipeline).
- [ ] Rehearse the whole demo end to end against the live stack at least once before the audit, timed.

---

## 8. Bonus (optional, after everything above)

Already claimable: own `crud-master` / `play-with-containers` / `orchestrator` lineage, alerting through CloudWatch, SNS and Budgets, Inspector plus ECR scan-on-push, Cloud Map service discovery, the k3d-tested manifests, and the audit tooling.

Not implemented, from the brief's list:

- **FaaS:** a small Lambda would be enough, for example one subscribed to the SNS alert topic that posts to a chat webhook, or a scheduled one that exports CloudWatch logs to the S3 bucket.
- **CDN:** CloudFront in front of API Gateway. If you also want WAF, note that AWS WAF cannot be attached to an API Gateway **HTTP** API directly; it would sit on CloudFront.

---

## 9. Suggested order of work

1. Choose the TLS option (3.2) and the broker mode (3.1); decide whether to make the ALB internal (5.2).
2. Fix 3.1 to 3.8 and 5.1; run `terraform validate` and `terraform plan` (plan needs credentials).
3. Deploy (4.2) and fix whatever the first apply reveals (5.5).
4. Walk through 4.3 to 4.9 and save the real output.
5. Apply 5.3 and 5.4.
6. Update the README (6.1), the scripts (6.3) and `ecs-tasks/` (6.4); hand the `docs/` changes (6.2) to yourself as a separate step.
7. Rehearse (7), run the demo for the audit, then tear down (4.10).
