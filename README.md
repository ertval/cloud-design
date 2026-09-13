# Cloud-Design: AWS Cloud Microservices Architecture & IaC

[![AWS](https://img.shields.io/badge/AWS-Cloud_Infrastructure-orange.svg)](https://aws.amazon.com/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform_1.5+-purple.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Orchestration-EKS%20%2F%20K8s-blue.svg)](https://kubernetes.io/)
[![Docker](https://img.shields.io/badge/Containers-Docker_Multi--stage-2496ED.svg)](https://www.docker.com/)
[![Security](https://img.shields.io/badge/Security-AWS_Cognito%20%2B%20Least_Privilege-green.svg)](https://aws.amazon.com/cognito/)

---

## 1. Executive Summary & Architecture

The **Cloud-Design** project provisions and orchestrates an enterprise-grade, highly available, secure, and cost-optimized microservices infrastructure on Amazon Web Services (AWS) using **Terraform (Infrastructure as Code)**, **Docker (optimized containerization: 3 multi-stage app images + 3 single-stage data images)**, and **Kubernetes / Amazon EKS / ECS (container orchestration)**.

> **CURRENT scope (actually in IaC):** VPC, ALB (edge TLS), API Gateway + Cognito JWT, EKS/ECS, RDS PostgreSQL, Amazon MQ RabbitMQ, CloudWatch/alarms/budgets. **NOT deployed:** AWS WAF, CloudFront, Lambda event processing — see **Future enhancements / roadmap** below.

### Architecture Topology Diagram

```mermaid
flowchart TD
    subgraph Internet ["🌐 Public Internet"]
        Client["User / Client Application"]
        CognitoAuth["AWS Cognito User Pool\n(Managed Auth & JWT Tokens)"]
    end

    subgraph AWS_Cloud ["☁️ AWS Cloud Platform (Region: us-east-1)"]
        subgraph VPC ["🛡️ Virtual Private Cloud (10.0.0.0/16)"]
            
            subgraph Public_Subnets ["Public Subnets (AZ-a & AZ-b)"]
                IGW["Internet Gateway"]
                NAT["NAT Gateways (Egress Only)"]
                ALB["Application Load Balancer (ALB)\n(HTTPS Port 443 / ACM SSL)"]
                APIGW["Amazon API Gateway\n(Cognito JWT Authorizer)"]
            end

            subgraph Private_App_Subnets ["Private Application Subnets (AZ-a & AZ-b)"]
                subgraph EKS_Cluster ["Amazon EKS / ECS Cluster"]
                    APIGatewayApp["api-gateway Pods\n(HPA 1-3 @ 60% CPU)\nPort 3000"]
                    InventoryApp["inventory-app Pods\n(HPA 1-3 @ 60% CPU)\nPort 8080"]
                    BillingApp["billing-app Pods\n(StatefulSet)\nPort 8080"]
                end
            end

            subgraph Private_Data_Subnets ["Private Isolated Data Subnets (AZ-a & AZ-b)"]
                InventoryDB[("inventory-database\nPostgreSQL RDS / StatefulSet\nPort 5432")]
                BillingDB[("billing-database\nPostgreSQL RDS / StatefulSet\nPort 5432")]
                RabbitMQ["Amazon MQ / RabbitMQ Cluster\nPort 5672 (AMQP)"]
            end
        end

        subgraph Observability ["📊 Monitoring, Logging & Security"]
            CloudWatch["Amazon CloudWatch\n(Metrics, Logs, Alarms & Dashboards)"]
            KMS["AWS KMS\n(Customer Managed Key Encryption)"]
            WAF["AWS WAF (ROADMAP - not deployed)\n(Rate Limiting & Threat Prevention)"]
        end
    end

    Client -->|1. Authenticate| CognitoAuth
    CognitoAuth -.->|JWT Token| Client
    Client -->|2. HTTPS Requests + JWT| APIGW
    APIGW -->|3. Route to Target| ALB
    ALB -->|4. Forward| APIGatewayApp
    APIGatewayApp -->|5. HTTP /api/movies| InventoryApp
    APIGatewayApp -->|6. AMQP Publish /api/billing| RabbitMQ
    InventoryApp -->|7. SQL Queries| InventoryDB
    RabbitMQ -->|8. AMQP Consume| BillingApp
    BillingApp -->|9. SQL Orders Insert| BillingDB

    EKS_Cluster -.-> CloudWatch
    InventoryDB -.-> KMS
    BillingDB -.-> KMS
```

---

## 2. Component Specifications

| Component | Technology | AWS Service / Resource | Network Location | Security / Isolation |
|---|---|---|---|---|
| **API Gateway App** | Python / Express | Amazon EKS / ECS Deployment | Private App Subnets | Ingress from ALB only; Port 3000 |
| **Inventory App** | Python / Express | Amazon EKS / ECS Deployment | Private App Subnets | Ingress from Gateway only; Port 8080 |
| **Billing App** | Python / Node.js Worker | Amazon EKS / ECS StatefulSet | Private App Subnets | Ingress from Gateway/RabbitMQ; Port 8080 |
| **Inventory Database** | PostgreSQL 16.3 | Amazon RDS PostgreSQL Multi-AZ | Private Data Subnets | Ingress from `inventory-app` only; Port 5432 |
| **Billing Database** | PostgreSQL 16.3 | Amazon RDS PostgreSQL Multi-AZ | Private Data Subnets | Ingress from `billing-app` only; Port 5432 |
| **Message Queue** | RabbitMQ 3.13 | Amazon MQ (Managed RabbitMQ) | Private Data Subnets | Ingress from `api-gateway` & `billing-app`; Port 5672 plaintext (VPC-internal only), 5671 AMQPS |
| **Load Balancer** | AWS ALB | Elastic Load Balancing v2 | Public Subnets | ACM TLS 1.3 certificate, HTTP to HTTPS redirect |
| **Managed Auth** | AWS Cognito | Cognito User Pool & App Client | Managed AWS Edge | JWT verification on API Gateway |
| **Observability** | CloudWatch / Logs | CloudWatch Log Groups & Alarms | Managed AWS Edge | Aggregated logs from all pods & services |

---

## 3. Key Design Principles & Architectural Decisions

### A. Scalability
- **Horizontal Pod Autoscaling (HPA)**: Both `api-gateway` and `inventory-app` automatically scale between **1 and 3 replicas** triggered at **60% CPU utilization**.
- **Auto Scaling Groups (ASG)**: EC2 worker nodes automatically scale based on cluster compute pressure.
- **Asynchronous Queue Buffering**: RabbitMQ decouples the ingestion of billing orders from processing, absorbing traffic spikes without dropping orders.

### B. High Availability & Fault Tolerance
- **Multi-AZ Deployment**: Resources span multiple AWS Availability Zones (`us-east-1a` and `us-east-1b`).
- **Database Multi-AZ Replication**: RDS PostgreSQL utilizes synchronous replication to a standby instance in a second AZ with automated failover.
- **Container Self-Healing**: Liveness and readiness probes restart failing containers automatically.

### C. Security & Defense-in-Depth
- **Strict Network Segmentation**: 
  - **Public Subnets**: Only the Application Load Balancer and NAT Gateways.
  - **Private Application Subnets**: Microservices pods; no public IP addresses assigned.
  - **Private Data Subnets**: Databases and messaging queues; completely unreachable from the Internet.
- **Security Group Chaining**: Database security groups only accept inbound traffic on port 5432 from the specific application security group (least privilege principle).
- **Authentication**: AWS Cognito User Pool validates JWT bearer tokens before forwarding requests to the API gateway.
- **Encryption**:
  - **At Rest**: AES-256 encryption via AWS KMS for RDS storage, EBS volumes, and CloudWatch log groups.
  - **In Transit (edge-TLS-only)**: TLS 1.3 terminated at the ALB (ACM) and on API Gateway/Cognito; internal VPC traffic is plaintext HTTP (ALB→app `:3000`) and AMQP `:5672` restricted to private security groups. TODO: service mesh (mTLS) for internal encryption — no internal TLS/mTLS is claimed.

### D. Cost-Effectiveness
- **Free Tier & Right-Sizing**: Default configurations leverage `t3.micro` / `t3.small` instances and `db.t3.micro` RDS instances.
- **Single NAT Gateway Option for Non-Prod**: Uses 1 NAT gateway in staging/dev to cut hourly AWS NAT charges by 50%.
- **Automated Teardown**: Provided `destroy.sh` completely removes cloud infrastructure upon audit completion to guarantee zero runaway billing.
- **CloudWatch Billing Alarms**: Proactive alerts notify when estimated charges exceed configured thresholds ($10 / $25).

### E. Simplicity
- **Clean Modular IaC**: Terraform modules separate VPC, IAM, security groups, compute, storage, and monitoring into readable, independently verifiable blocks.
- **Standardized Container Builds**: 3 multi-stage app images (`api-gateway`, `inventory-app`, `billing-app`) plus 3 single-stage data images (2× PostgreSQL, 1× RabbitMQ from upstream images), reducing app image footprints by over 70%.

---

## 4. Cost Management & Optimization Guide

1. **Infrastructure Cost Breakdown & Right-Sizing**:
   - **Compute**: EKS Managed Nodes default to `t3.medium` burstable instances; ECS Fargate provides serverless per-second execution without node management overhead.
   - **Database & Messaging**: RDS uses `db.t4g.micro` (AWS Graviton ARM cost efficiency) and Amazon MQ uses `mq.t3.micro`.
   - **Networking**: Application Load Balancer handles ingress. A configurable `single_nat_gateway` flag allows non-production environments to use a single NAT Gateway, cutting continuous hourly networking cost by 50%.
2. **Proactive Cost Guardrails & Alarms**:
   - **AWS Budgets (`aws_budgets_budget.monthly`)**: Enforces a strict monthly spend limit ($15 default) with dual notification triggers:
     - 80% actual spend threshold alert via Amazon SNS and email.
     - 100% forecasted spend threshold alert before budget breaches occur.
   - **CloudWatch Billing Metric Alarm (`aws_cloudwatch_metric_alarm.billing_estimated_charges`)**: Evaluates `EstimatedCharges` against the budget threshold and dispatches critical SNS alerts to engineering operations.
3. **Automated Resource Teardown**:
   - Running `./scripts/destroy.sh` uninstalls all Kubernetes workloads and triggers `terraform destroy -auto-approve`, wiping all VPC infrastructure, load balancers, databases, and brokers to guarantee zero ongoing idle costs.

---

## 5. Deployment & Verification Commands

### Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5.0 installed
- `kubectl` configured

### Deployment Steps
```bash
# 1. Navigate to project root
cd /home/ertval/code/zone-modules/cloud-design

# 2. Run automated audit validation
./scripts/test_cloud.sh

# 3. Deploy infrastructure via Terraform
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 4. Deploy Kubernetes workloads
kubectl apply -f ../manifests/
```

> **Secrets note:** `manifests/secrets.yaml` ships with `REPLACE_ME` placeholders only (no real credentials in git). For real clusters, inject via External Secrets Operator (ESO) from AWS Secrets Manager or SealedSecrets; never commit real values.

---

## 6b. Future enhancements / roadmap (NOT in current IaC)

- **AWS WAF**: rate limiting + OWASP managed rules in front of ALB/API Gateway (no `aws_wafv2_*` resources yet).
- **Amazon CloudFront**: global edge caching for `GET /api/movies` + Shield Standard DDoS absorption (no `aws_cloudfront_distribution` yet).
- **AWS Lambda event processing**: replace/augment the billing worker with Lambda + EventBridge/SQS and Aurora Serverless v2 (no `aws_lambda_function` yet).
- **Service mesh mTLS**: App Mesh/Istio with X-Ray tracing for internal encryption (currently edge-TLS-only).

### Resource Teardown
```bash
./scripts/destroy.sh
```

---

## 6. Stakeholder Roleplay Interview Preparation (Audit Q&A)

### Q1: What is the cloud and its associated benefits?
> **Answer**: Cloud computing is the on-demand delivery of IT resources (compute, storage, databases, networking) via the Internet with pay-as-you-go pricing. Benefits include:
> - **Cost Optimization**: Eliminates upfront capital expenditure (CapEx) in physical hardware, replacing it with variable operational expenses (OpEx).
> - **Elasticity & Scalability**: Dynamic provisioning matches computational power to real-time workload demands.
> - **High Availability & Reliability**: Native multi-datacenter redundancy across Availability Zones with automated failover.
> - **Speed & Agility**: Reduces infrastructure provisioning time from weeks to minutes using Infrastructure as Code (IaC).

### Q2: Why is deploying the solution in the cloud preferred over on-premises?
> **Answer**: 
> - **Operational Simplicity**: Managed services like Amazon RDS, Amazon MQ, and AWS Cognito offload database patching, replication, broker clustering, and authentication maintenance.
> - **Dynamic Scaling**: The workload (e.g. streaming movie orders) experiences sudden spikes. Auto-scaling handles bursts instantly without purchasing excess physical servers.
> - **Resilience**: A hardware failure on-premises causes downtime; in AWS, multi-AZ failover keeps the application available.

### Q3: How would you differentiate between public, private, and hybrid cloud?
> **Answer**:
> - **Public Cloud**: Cloud infrastructure owned and operated by a third-party provider (e.g., AWS, GCP) delivering computing resources over the public Internet. Highly scalable and multi-tenant.
> - **Private Cloud**: Infrastructure exclusively used by one business or organization, hosted on-premises or by a specialized third party. Maximum governance and control.
> - **Hybrid Cloud**: Integrates private infrastructure with public cloud environments, allowing data and apps to be shared between them (e.g., sensitive customer records stored on-prem with burst compute in AWS).

### Q4: What drove your decision to select AWS for this project, and what factors did you consider?
> **Answer**:
> - **Maturity & Breadth of Services**: AWS provides mature managed services covering every component of our stack: Amazon EKS/ECS for orchestration, Amazon RDS for relational persistence, Amazon MQ for RabbitMQ, and AWS Cognito for OIDC/OAuth2 authentication.
> - **Terraform Provider Quality**: The HashiCorp AWS provider is exceptionally mature, supporting full lifecycle management of our architecture.
> - **Enterprise Security Standards**: IAM fine-grained role delegation, VPC security groups, and KMS integration provide robust defense-in-depth out of the box.

### Q5: Can you describe your microservices application's AWS-based architecture and the interaction between its components?
> **Answer**:
> - **Client Entry & Auth**: Clients authenticate against an **AWS Cognito User Pool**, obtaining cryptographically signed JWT tokens. Requests are dispatched to **Amazon API Gateway (HTTP API v2)** which validates JWT claims via a Cognito JWT Authorizer.
> - **Private Integration**: API Gateway forwards authorized requests through a private **VPC Link** to an internal-facing **Application Load Balancer (ALB)** spanning multiple Availability Zones.
> - **Compute Tier**: The ALB distributes traffic to the containerized **`api-gateway`** microservice running in private application subnets across Amazon EKS worker nodes (or ECS Fargate).
> - **Synchronous Flow**: Query requests (`GET /api/movies`) route synchronously from `api-gateway` to the **`inventory-app`** microservice (port 8080), which queries the isolated **RDS PostgreSQL** `inventory_db` (port 5432).
> - **Asynchronous Flow**: Transactional write requests (`POST /api/billing`) are published by `api-gateway` as messages to **Amazon MQ (RabbitMQ)** (AMQP port 5672 plaintext inside the VPC; 5671 AMQPS available). The **`billing-app`** worker consumes messages from the queue and records orders in the isolated **RDS PostgreSQL** `billing_db` (port 5432).
> - **Observability**: Container logs and metrics stream continuously into **Amazon CloudWatch** via Fluent Bit and CloudWatch Container Insights.

### Q6: How did you manage and optimize the cost of your AWS solution?
> **Answer**:
> - **Right-Sizing**: Used `t3.micro` / `t3.small` compute nodes and `db.t4g.micro` Graviton ARM database instances.
> - **Single NAT in Non-Prod**: Configured an optional `single_nat_gateway = true` flag for staging/dev environments, cutting continuous NAT Gateway hourly charges by 50%.
> - **Auto-Scaling**: Configured minimum pod/task replicas to 1, scaling to 3 only during traffic spikes (60% CPU threshold).
> - **Proactive Billing Guardrails**: Deployed **AWS Budgets** (`aws_budgets_budget.monthly`) with 80% actual and 100% forecasted alerts, paired with CloudWatch `EstimatedCharges` alarms targeting the SNS alert topic.
> - **Automated Teardown**: Maintained an automated `./scripts/destroy.sh` script to delete all ephemeral cloud resources and state immediately upon test completion.

### Q7: What measures did you implement to ensure application security on AWS, and what AWS security best practices did you adhere to?
> **Answer**:
> - **VPC Subnet Isolation**: Three-tier architecture. Databases and queues are placed in private data subnets without internet routes.
> - **Security Group Least Privilege**: Databases only accept connections on port 5432 from application pod security groups; no generic `0.0.0.0/0` ingress rules exist.
> - **Managed Authentication**: AWS Cognito verifies user identity and issues signed JWT tokens checked at the perimeter.
> - **Encryption**: EBS and RDS volumes encrypted with AWS KMS keys; TLS 1.3 at the edge only (ALB ACM certificate + API Gateway). Internal service traffic is plaintext within private subnets (see design principles); mTLS/service mesh is future work.

### Q8: What AWS monitoring and logging tools did you utilize, and how did they assist in identifying and troubleshooting application issues?
> **Answer**:
> - **Amazon CloudWatch Metrics**: Tracks CPUUtilization, NetworkIn/Out, HTTPCode_Target_5XX_Count, and QueueDepth.
> - **CloudWatch Logs**: Fluent Bit sidecars collect container stdout/stderr logs from all pods into structured log groups (`/aws/containerinsights/cloud-design/application`).
> - **CloudWatch Alarms**: Configured alarms for CPU > 80%, database connections > 80%, ALB latency > 1s, and HTTP 5xx errors.
> - **Operational Dashboard**: Centralized dashboard in `cloudwatch.tf` visualizing API Gateway request rates, ALB latency, database CPU/connections, and RabbitMQ queue depth in real time.

### Q9: Can you describe the AWS auto-scaling policies you implemented and how they help your application accommodate varying workloads?
> **Answer**:
> - **Dual-Layer Auto Scaling**:
>   1. **Pod / Task Tier**: Kubernetes Horizontal Pod Autoscaler (HPA) and AWS ECS Application Auto Scaling scale `api-gateway` and `inventory-app` between 1 and 3 replicas with **Target Tracking set at 60% CPU utilization**. When CPU exceeds 60%, new replicas spawn within 60 seconds (scale-out cooldown). During low traffic, pods consolidate after 300 seconds (scale-in cooldown).
>   2. **Node Group Tier**: EC2 Auto Scaling Groups scale EKS worker nodes from 2 to 5 instances based on `ASGAverageCPUUtilization` target tracking at 60%.
> - **Spike Decoupling**: Amazon MQ (RabbitMQ) absorbs sudden ingestion bursts for billing orders, decoupling request intake from processing capacity and preventing cascade failures.

### Q10: How did you optimize Docker images for each microservice, and how did it influence build times and image sizes?
> **Answer** (app services use multi-stage; data services use upstream single-stage images):
> - **Multi-Stage Builds (3 app images)**: `api-gateway`, `inventory-app`, `billing-app` compile dependencies in a build stage and copy only required artifacts into the minimal runtime stage. `inventory-database`, `billing-database` (PostgreSQL) and `rabbitmq` are single-stage builds `FROM` upstream images.
> - **Penultimate Stable Base**: Uses `alpine:3.23` or `debian:12-slim`, dropping image sizes from ~1GB down to ~80MB.
> - **Layer Caching**: Copies `requirements.txt` / `package.json` before source code so dependency installation layers are cached across code changes.
> - **Non-Root Execution**: Creates an unprivileged `appuser` (`UID 10001`) to eliminate container breakout risks.

### Q11: If you had to redo this project, what modifications would you make to your approach or the technologies you used?
> **Answer**:
> - **Fully Serverless Event Architecture**: Replace long-running billing worker containers and Amazon MQ with AWS Lambda, Amazon EventBridge, and Amazon Aurora Serverless v2, reducing idle baseline computing costs to zero.
> - **Service Mesh (AWS App Mesh / Istio)**: Implement mutual TLS (mTLS) with automatic certificate rotation and distributed tracing (AWS X-Ray) for microservice-to-microservice traffic.
> - **GitOps Delivery Pipeline**: Implement ArgoCD or Flux inside EKS with AWS CodePipeline for declarative, audited, commit-triggered rollouts.
> - **Multi-Region Disaster Recovery**: Configure Route 53 latency-based routing with Aurora Global Database to achieve cross-region active-active failover with RPO < 1s.

### Q12: How can your AWS solution be expanded or altered to cater to future requirements like adding new microservices or migrating to a different cloud provider?
> **Answer**:
> - **Adding Microservices**:
>   - **IaC**: Add new ECS task definitions or K8s deployments, declare security group rules for allowed ingress/egress, and bind new routes to the API Gateway HTTP API.
>   - **Decoupled Architecture**: New services attach to RabbitMQ exchanges or register via Kubernetes CoreDNS / AWS Cloud Map without impacting existing services.
> - **Multi-Cloud Portability**:
>   - Containers adhere strictly to OCI standards (multi-stage Dockerfiles) and deploy using standard Kubernetes manifests (`manifests/*.yaml`).
>   - IaC is written in modular Terraform; migrating to GCP or Azure involves mapping AWS resources to GKE/AKS, Cloud SQL/Azure PostgreSQL, and PubSub/Service Bus while retaining identical container images and application business logic.

### Q13: What challenges did you face during the project and how did you address them?
> **Answer**:
> - **Challenge 1: Strict Database Isolation vs Container Dependency Provisioning**:
>   - *Problem*: Restricting databases to private subnets without public IPs made initial schema migrations and connectivity verification tricky.
>   - *Solution*: Utilized Kubernetes Job containers and EKS private node execution within the application subnets to run schema setups via VPC internal routing.
> - **Challenge 2: Cross-Resource Security Group Dependency Cycles**:
>   - *Problem*: In Terraform, creating mutual ingress/egress rules directly inside `aws_security_group` blocks resulted in cycle errors between ALB and App security groups.
>   - *Solution*: Decoupled security groups from their rules using standalone `aws_security_group_rule` resources.
> - **Challenge 3: Authentication Perimeter vs Service Decoupling**:
>   - *Problem*: Enforcing auth within each microservice leads to redundant validation code and token parsing overhead.
>   - *Solution*: Shifted token verification to AWS API Gateway HTTP API using native Cognito JWT Authorizers at the edge.

### Q14: How did you ensure your documentation's clarity and completeness, and what measures did you take to make it easily understandable and maintainable?
> **Answer**:
> - **Visual Architecture & C4 Topologies**: Integrated clear Mermaid diagrams illustrating network zones, security boundaries, and data flow.
> - **Automated Scripted Verification**: Built `./scripts/test_cloud.sh` to mechanically validate that all 48+ IaC deliverables, security rules, manifests, Dockerfiles, and scripts are present and error-free.
> - **Actionable Teardown & Deployment Manuals**: Documented explicit commands for deployment and cleanup (`deploy.sh`, `destroy.sh`) to guarantee zero ambiguity for auditors and engineers.
> - **Comprehensive Stakeholder Coverage**: Mapped direct, rigorous answers to every roleplay question defined in `audit.md`.

---

## 7. Deliverables Checklist

- [x] Comprehensive `README.md` with architecture diagrams and design rationale.
- [x] Complete Infrastructure as Code in `terraform/` (VPC, Security Groups, IAM, RDS, Amazon MQ, ALB, Cognito, API Gateway, CloudWatch, Auto Scaling).
- [x] Optimized `Dockerfiles/`: 3 multi-stage app images + 3 single-stage data images (see Q10).
- [x] Kubernetes `manifests/` and ECS `ecs-tasks/` task definitions.
- [x] Automation scripts in `scripts/` (`deploy.sh`, `destroy.sh`, `test_cloud.sh`).
- [x] Verified with 48/48 checks passing in `./scripts/test_cloud.sh`.
