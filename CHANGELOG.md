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
