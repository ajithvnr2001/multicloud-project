---
title: "DevOps Interview-Ready Portfolio: 5 End-to-End Multi-Cloud Projects"
tags:
  - devops
  - gcp
  - aws
  - azure
  - kubernetes
  - terraform
  - gitops
  - argocd
  - opentelemetry
  - grafana
  - observability
  - devsecops
  - disaster-recovery
  - three-tier-architecture
  - interview-preparation
  - production-readiness
author: "Ajith Kumar"
last_updated: "2026-07-14"
version: "1.0"
scope: "3 YOE DevOps Engineer - 60 Day Interview Prep"
---

# DevOps Interview-Ready Portfolio: 5 End-to-End Projects
### Multi-Cloud (GCP / AWS / Azure) | 3 YOE DevOps Engineer | 60-Day Prep

---

## Table of Contents
1. Project 1: Containerize & Auto-Deploy Web App
2. Project 2: IaC Kubernetes Cluster
3. Project 3: GitOps Microservices with ArgoCD
4. Project 4: OpenTelemetry + Grafana LGTM Observability Stack
5. Project 5: Multi-Cloud DevSecOps + DR + Cost Control
6. Cross-Project Integration Map
7. 60-Day Execution Timeline

---

# PROJECT 1: Containerize & Auto-Deploy Web App

## Goal
Take a simple app (Node.js/Python), containerize it, build a CI/CD pipeline, deploy to a managed compute service. Foundation project — teaches Docker, registries, pipeline-as-code.

## End-to-End Architecture

```
Developer Push (Git)
      |
      v
CI Trigger (Cloud Build / CodeBuild / Azure Pipelines)
      |
      v
Build Stage --> Unit Tests --> Docker Build --> Image Scan (Trivy)
      |
      v
Push to Registry (Artifact Registry / ECR / ACR)
      |
      v
Deploy Stage --> Target Compute
      |
      +--> GCP: Cloud Run (serverless) or Compute Engine (VM)
      +--> AWS: ECS Fargate or EC2
      +--> Azure: Container Apps or Azure VM
      |
      v
Health Check --> Traffic Live --> Rollback on Failure
```

## Phase-by-Phase Build

### Phase 1: Local Containerization
- Write multi-stage Dockerfile (build stage + slim runtime stage)
- Add .dockerignore, healthcheck instruction
- Test locally with docker run + docker-compose for dependencies (DB, cache)

**GCP tools:** Cloud Code, gcloud CLI
**AWS tools:** AWS CLI, SAM CLI (optional)
**Azure tools:** Azure CLI, VS Code Azure extension

### Phase 2: Registry Setup
- GCP: Create Artifact Registry repo, configure Docker auth (`gcloud auth configure-docker`)
- AWS: Create ECR repo, `aws ecr get-login-password`
- Azure: Create ACR, `az acr login`

### Phase 3: CI Pipeline
- Write pipeline config (cloudbuild.yaml / buildspec.yml / azure-pipelines.yml)
- Stages: lint -> test -> build -> scan -> push -> deploy
- Add Trivy or native scanner (Artifact Analysis / ECR Scan / Defender for Cloud) as a gate

### Phase 4: Deployment
- GCP: `gcloud run deploy` with min/max instances, concurrency, CPU throttling config
- AWS: ECS Task Definition + Service, Fargate launch type, ALB target group
- Azure: Container App with revision-based traffic splitting

### Phase 5: Validation & Rollback
- Smoke test post-deploy
- Configure automatic rollback on failed health check
- Tag images with commit SHA for traceability

## Interview Questions & Debug Scenarios

### Conceptual
- What's the difference between COPY and ADD in a Dockerfile?
- Why use multi-stage builds? What problem does it solve?
- Explain the difference between an image layer cache hit and a cache miss.

### Scenario-Based
- **Q:** Your container builds fine locally but crashes with "exec format error" on the cloud VM.
  **A:** Architecture mismatch (built on ARM Mac, deployed to AMD64 VM). Fix: use `docker buildx build --platform linux/amd64`.
- **Q:** Image size ballooned to 2GB — how do you shrink it?
  **A:** Switch to alpine/distroless base, multi-stage build to drop build tools, remove cache layers (`--no-cache`), use `.dockerignore`.
- **Q:** The pipeline pushes a new image but the running service never updates.
  **A:** Check if deploy step pins `:latest` tag (Cloud Run/ECS may cache) — always deploy by digest or commit SHA, force new revision/task definition.
- **Q:** Trivy scan blocks the pipeline on a CVE in a base image you don't control.
  **A:** Triage severity vs exploitability, add temporary allowlist with expiry, or switch base image; document risk acceptance if truly unavoidable.
- **Q:** Deployment succeeds but health checks fail intermittently in ECS/Cloud Run.
  **A:** Check cold start time vs health check timeout, increase initial delay, verify app listens on correct PORT env var.

---

# PROJECT 2: IaC Kubernetes Cluster (Full Production-Grade 3-Tier Architecture)

> **Implementation Note**: Complete working code, Terraform files, Kubernetes manifests, Cloud Build pipelines, and in-depth troubleshooting guides for Phase 2 are located in the [`phase2/`](./phase2/) directory.

## Goal
Provision a production-grade managed Kubernetes cluster entirely via Terraform, deploy a genuine 3-tier application (Web/Presentation, Application/Logic, Data) with proper network segmentation, security boundaries, and high availability across GCP (GKE Dataplane V2 / Cilium eBPF, Cloud SQL PostgreSQL, Workload Identity, and Cloud Armor Ingress), AWS (EKS), and Azure (AKS).

## The Classic 3-Tier Model (Network + Compute View)

```
                               INTERNET
                                  |
                                  v
                     +------------------------+
                     |   CDN / WAF (edge)     |
                     |   (GCP Cloud Armor)    |
                     +------------------------+
                                  |
                                  v
                  +-------------------------------+
                  |  PUBLIC SUBNET (Tier 1: Web)   |
                  |  - Load Balancer (L7 Ingress)  |
                  |  - Container-Native NEGs       |
                  |  - Frontend pods / Nginx       |
                  |  - BackendConfig / Drain 60s   |
                  +-------------------------------+
                                  |
                      (Private routing only)
                                  v
                  +-------------------------------+
                  |  PRIVATE SUBNET (Tier 2: App)  |
                  |  - GKE Private Node Pool (COS) |
                  |  - Node.js API pods (8080)     |
                  |  - Cloud SQL Auth Proxy sidecar|
                  |  - Workload Identity (IAM)     |
                  |  - HPA Auto-Scaling (2-10 pods)|
                  +-------------------------------+
                                  |
                      (Private Service Access / PSA VPC Peering)
                                  v
                  +-------------------------------+
                  |  DATA SUBNET (Tier 3: Database)|
                  |  - Managed Cloud SQL Postgres |
                  |  - Private IP only (10.0.3.0)  |
                  |  - No Public IP | Encrypted TLS|
                  +-------------------------------+
```

## Cloud-Specific Production Mapping

| Tier | GCP (Phase 2 Implemented) | AWS | Azure |
|---|---|---|---|
| Edge/CDN/WAF | Cloud Armor WAF + Global HTTP(S) Load Balancer (`05-production-ingress.yaml`) | CloudFront + AWS WAF | Azure Front Door + WAF |
| Tier 1 (Web/Presentation) | Nginx Pods with Container-Native NEGs, ClusterIP Service, `BackendConfig` | EC2/EKS pods in public subnet, ALB | AKS pods in public subnet, App Gateway |
| Tier 2 (App/Logic) | Private GKE Node Pool (`n1-standard-1` in `us-east4-a`), Dataplane V2 eBPF NetworkPolicies, Workload Identity (`roles/iam.workloadIdentityUser`), Cloud SQL Proxy 2.x Sidecar | EKS pods in private subnet, internal NLB, IRSA | AKS pods in private subnet, internal LB, Workload Identity |
| Tier 3 (Data/Isolated) | Cloud SQL PostgreSQL 15 via Private Service Access (PSA Peering), no public IP | RDS Multi-AZ (private subnet, no public access) or StatefulSet + EBS | Azure SQL/Postgres Flexible Server (private endpoint) or StatefulSet + Azure Disk |
| Network segmentation | VPC-native secondary alias IPs (`gke-pods: 10.100.0.0/16`, `gke-services: 10.101.0.0/20`), Cloud NAT & Router | Public/private/data subnets across AZs, Security Groups + NACLs per tier | VNet with subnets per tier, NSGs per subnet |
| Tier-to-tier security | eBPF NetworkPolicy: Tier 1 -> Tier 2 on 8080; Tier 2 -> Cloud SQL on 5432 & DNS on 53; deny all unauthorized traffic | SG: web-sg -> app-sg (port 8080); app-sg -> db-sg (port 5432); web-sg has NO route to db-sg | NSG: web-nsg -> app-nsg; app-nsg -> db-nsg; web-nsg blocked from db-nsg |

## Phase 2 Deliverables & File Layout

All source code and manifests are organized under [`phase2/`](./phase2/):

- **Terraform Infrastructure ([`phase2/terraform/`](./phase2/terraform/))**:
  - `main.tf`, `variables.tf` (Region: `us-east4`, avoids stockouts & location policies).
  - `vpc.tf` (VPC, Subnets, Cloud NAT & Router, Private Service Access).
  - `gke.tf` (Private Cluster, Dataplane V2, `n1-standard-1` Node Pool, `deletion_protection = false`, `lifecycle` drift rules).
  - `cloudsql.tf` (Private Cloud SQL PostgreSQL 15, `random_password`).
  - `iam.tf` (GKE Node SA, Workload Identity Binding with `depends_on = [google_container_cluster.gke_cluster]`).
  - `outputs.tf` (`gke_get_credentials_command`, `cloudsql_connection_name`, `db_password`).
- **Kubernetes Manifests ([`phase2/k8s/`](./phase2/k8s/))**:
  - `00-namespaces-rbac.yaml` (Workload Identity ServiceAccount).
  - `01-network-policies.yaml` (eBPF micro-segmentation).
  - `02-tier1-frontend.yaml` (Nginx + NEG + BackendConfig).
  - `03-tier2-backend.yaml` (Multi-container Node.js API + Cloud SQL Proxy 2.8.1).
  - `04-hpa-autoscaling.yaml` (HPA CPU > 70%, 2 to 10 replicas).
  - `05-production-ingress.yaml` (Global L7 Load Balancer + BackendConfig).
- **CI/CD Pipeline ([`phase2/cloudbuild.yaml`](./phase2/cloudbuild.yaml))**:
  - Node.js test $\rightarrow$ Docker build $\rightarrow$ Trivy CVE scanning $\rightarrow$ Artifact Registry push $\rightarrow$ GKE rolling update.
- **Deep-Dive Engineering Documentation**:
  - [`phase2/project_2_gcp_guide.md`](./phase2/project_2_gcp_guide.md): Complete architecture guide and 9 break-and-learn test cases.
  - [`phase2/triagephase2.md`](./phase2/triagephase2.md): Incident RCA on all 10 real errors, fixes, and senior interview questions.
  - [`phase2/kubectl-commands-guide.md`](./phase2/kubectl-commands-guide.md): Exhaustive guide covering all 16 GKE default system pods/daemons, storage controllers, CRDs, and `kubectl` master reference.

## Interview Questions & Debug Scenarios (3-Tier & GKE Specific)

### Conceptual
- **Why use Workload Identity instead of mounting a GCP Service Account JSON key as a Kubernetes Secret?**
  *Answer*: Static JSON keys never expire, risk exposure in Git/logs, and require manual key rotation. Workload Identity uses the local metadata server emulator (`gke-metadata-server`) to dynamically exchange KSA JWT tokens for short-lived (1-hour) OAuth 2.0 access tokens directly from Google STS.
- **What is GKE Dataplane V2 (`ADVANCED_DATAPATH`) and why is it superior to `kube-proxy`?**
  *Answer*: Dataplane V2 replaces `kube-proxy` iptables packet filtering with Cilium eBPF bytecode loaded into the Linux kernel. It provides $O(1)$ constant-time routing lookups (vs $O(N)$ linear degradation in iptables), direct Pod-to-Pod routing via Container-Native NEGs, and kernel-level NetworkPolicy enforcement.
- **Why did Terraform fail with `Identity Pool does not exist (PROJECT_ID.svc.id.goog)` during cluster creation?**
  *Answer*: The GCP Workload Identity Pool is created asynchronously by GCP only after the GKE control plane finishes provisioning. If the IAM binding runs in parallel, Google IAM rejects the call with HTTP 400. Solution: add an explicit `depends_on = [google_container_cluster.gke_cluster]` on the IAM resource.

### Scenario-Based
- **Q:** Your cluster creation fails with `GCE_STOCKOUT` in `us-central1`. How do you recover?
  **A:** Stockouts occur when GCP data centers exhaust physical compute allocations for a machine family (e.g. `e2`). Remediate by shifting to an enterprise hardware family (e.g. `n1-standard-1`) or relocating to an alternative compliant region (e.g. `us-east4`).
- **Q:** When destroying infrastructure, `google_service_networking_connection` fails with `Producer services are still using this connection`.
  **A:** Cloud SQL Private Service Access (PSA) VPC Peering retains internal tenant network interfaces in a tombstone state for 5–15 minutes after database deletion. Remove the resource from Terraform state (`terraform state rm`) and clean up the VPC via `gcloud`.
- **Q:** How do Pod Auto-Scaling (HPA) and Node Auto-Scaling (Cluster Autoscaler) interact under traffic load?
  **A:** When incoming traffic drives CPU $> 70\%$, HPA scales pods from 2 to 10. When the existing 2 nodes run out of CPU/RAM to host the new pods, pods enter `Status: Pending`. The GKE Cluster Autoscaler detects pending pods and calls Compute Engine API to boot up Node #3 (up to `max_node_count = 5`).
- **Q:** A `kubectl describe pod` shows Exit Code 137. What happened?
  **A:** Exit Code 137 indicates the pod was **OOMKilled** by the Linux kernel because container memory usage exceeded `resources.limits.memory`. Fix: increase memory limit or fix memory leaks in the Node.js application.

# PROJECT 3: GitOps Microservices with ArgoCD

## Goal
Multi-service app deployed declaratively via ArgoCD, with Helm-based environment overlays (dev/stage/prod) and automated sync from Git.

## End-to-End Architecture

```
Git Repo (source of truth)
   |
   +-- apps/auth (Helm chart)
   +-- apps/payments (Helm chart)
   +-- apps/frontend (Helm chart)
   +-- environments/dev/values.yaml
   +-- environments/stage/values.yaml
   +-- environments/prod/values.yaml
   |
   v
ArgoCD (watches Git repo)
   |
   +-- App-of-Apps pattern
   |
   v
Kubernetes Cluster (GKE / EKS / AKS)
   |
   +-- Auto-sync on Git change --> Deploy new revision
   +-- Health check via ArgoCD --> Sync status: Synced/OutOfSync/Degraded
   |
   v
Rollback: Git revert --> ArgoCD auto re-syncs to previous commit
```

## Phase-by-Phase Build

### Phase 1: Repo Structure
- Set up mono-repo: `apps/` (Helm charts per microservice), `environments/` (per-env values)
- Use Kustomize overlays as an alternative to Helm values if preferred

### Phase 2: ArgoCD Installation
- Install ArgoCD on cluster via Helm
- GCP/AWS/Azure: expose ArgoCD UI via Ingress + LoadBalancer, secure with SSO/OIDC

### Phase 3: App-of-Apps Pattern
- Create root Application that manages child Applications (auth, payments, frontend)
- Configure auto-sync policy: `automated: {prune: true, selfHeal: true}`

### Phase 4: Multi-Environment Promotion
- Dev auto-syncs on every commit
- Stage requires manual sync approval
- Prod requires PR merge + manual sync + smoke test gate

### Phase 5: Rollback & Progressive Delivery
- Test rollback via `argocd app rollback` or Git revert
- Optional: integrate Argo Rollouts for canary/blue-green within GitOps flow

## Interview Questions & Debug Scenarios

### Conceptual
- What is the core GitOps principle — why is Git the single source of truth?
- Difference between ArgoCD "sync" and "self-heal."
- App-of-Apps pattern — why use it over managing 10 separate Applications?

### Scenario-Based
- **Q:** ArgoCD shows "OutOfSync" but the cluster state actually looks correct.
  **A:** Likely a diff in fields ArgoCD tracks but doesn't matter (e.g., auto-injected annotations by a mutating webhook). Configure `ignoreDifferences` in the Application spec.
- **Q:** A bad Helm release just broke production — what's your rollback strategy?
  **A:** `argocd app rollback <app> <revision>` to previous synced revision, or `git revert` the commit and let auto-sync self-heal; always keep prod on manual-sync to catch issues before promotion.
- **Q:** You need the same app in dev/stage/prod with different resource limits — how do you structure this?
  **A:** Base Helm chart + per-environment values.yaml overrides, or Kustomize base + overlays; never duplicate full manifests per environment.
- **Q:** ArgoCD Application is stuck in "Progressing" indefinitely.
  **A:** Check pod readiness probes, check if a PVC is stuck in Pending (StorageClass issue), check ArgoCD health check hooks/timeout settings.
- **Q:** Secrets are committed in plaintext in a teammate's PR — how do you prevent this going forward?
  **A:** Adopt Sealed Secrets or External Secrets Operator (pulling from Secret Manager/Secrets Manager/Key Vault), add pre-commit hook + git-secrets scanning in CI.

---

# PROJECT 4: OpenTelemetry + Grafana LGTM Observability Stack

## Goal
Full observability layer: OTel Collector instruments and routes telemetry from Projects 1-3 into Grafana's LGTM stack (Loki, Grafana Mimir/Tempo).

## End-to-End Architecture

```
Instrumented App Pods (OTel SDK auto/manual instrumentation)
   |
   |  OTLP (gRPC 4317 / HTTP 4318)
   v
OTel Collector (DaemonSet or Deployment)
   |
   +-- Receivers: otlp
   +-- Processors: batch, memory_limiter, tail_sampling, k8sattributes
   +-- Exporters: -----------------------------
   |                                            |
   v                    v                       v
Grafana Mimir        Grafana Loki          Grafana Tempo
(metrics)             (logs)                (traces)
   |                    |                       |
   +--------------------+-----------------------+
                         v
                  Grafana (unified dashboards, Explore, Alerting)
                         |
                         v
             Alertmanager / SNS / Action Groups --> Slack/PagerDuty
```

## Phase-by-Phase Build

### Phase 1: Instrumentation
- Add OTel SDK to each microservice from Project 3 (auto-instrumentation agents where possible)
- Ensure trace context propagation (W3C traceparent headers) across service calls

### Phase 2: Collector Deployment
- Deploy OTel Collector via Helm with a config defining receivers/processors/exporters
- Tune `memory_limiter` and `batch` processor to prevent OOM under load
- Add `k8sattributes` processor to auto-tag telemetry with pod/namespace metadata

### Phase 3: Backend Storage
- Deploy Grafana Mimir (metrics), Loki (logs), Tempo (traces) — or start with Prometheus if Mimir is too heavy for a home lab
- Configure retention and storage backend (GCS / S3 / Azure Blob)

### Phase 4: Dashboards & Correlation
- Build Grafana dashboards: golden signals (latency, traffic, errors, saturation)
- Use Grafana Explore to jump from a trace ID -> correlated logs -> correlated metrics

### Phase 5: Alerting
- Define SLO-based alert rules (e.g., error rate > 1% over 5 min)
- Route via Alertmanager to Slack/PagerDuty; also compare with native cloud alerting (Cloud Monitoring alerts / CloudWatch Alarms / Azure Monitor Alerts)

## Interview Questions & Debug Scenarios

### Conceptual
- What are the three pillars of observability, and how does OTel unify them?
- Difference between a Collector receiver, processor, and exporter.
- Why is trace context propagation necessary across microservices?

### Scenario-Based
- **Q:** Traces appear in Tempo but metrics are missing in Mimir.
  **A:** Check the Collector's pipeline config — receivers/processors/exporters section per signal type; verify the metrics exporter isn't misconfigured or the memory_limiter isn't dropping the batch.
- **Q:** The OTel Collector pod gets OOMKilled during a traffic spike.
  **A:** Tune `memory_limiter` limit_mib/spike_limit_mib, add more Collector replicas behind a headless service, or offload to a gateway-mode Collector tier.
- **Q:** You see disconnected spans instead of one continuous trace across 3 services.
  **A:** Trace context isn't propagating — check that each service forwards the incoming traceparent header to downstream calls; verify instrumentation library version compatibility.
- **Q:** Trace/log storage costs are exploding.
  **A:** Apply tail-based sampling (keep 100% of errors/slow requests, sample the rest at low %), reduce log verbosity in production, set shorter retention on raw data with rollups.
- **Q:** How do you debug a slow API endpoint end-to-end using this stack?
  **A:** Start in Grafana dashboard (spot latency spike) -> Explore by traceID -> find the slow span (e.g., DB call) -> pivot to correlated logs at that timestamp -> check underlying metric (CPU/connection pool) for root cause.
- **Q:** How would you federate telemetry from clusters across GCP, AWS, and Azure into one Grafana?
  **A:** Each cluster runs its own OTel Collector in agent mode, forwarding to a central gateway Collector or directly to a shared Mimir/Loki/Tempo backend (self-hosted or Grafana Cloud) tagged with a `cloud` label for filtering.

---

# PROJECT 5: Multi-Cloud DevSecOps + DR + Cost Control

## Goal
Capstone project: security scanning gates, blue-green/canary deployments, disaster recovery automation, and cross-cloud cost optimization.

## End-to-End Architecture

```
CI Pipeline
   |
   +-- Static Analysis (SAST) --> SonarQube
   +-- Container Scan --> Trivy / native scanner
   +-- IaC Scan --> Checkov / tfsec
   |
   v
Deploy Gate (all scans pass)
   |
   v
Blue-Green / Canary Controller (Argo Rollouts / native traffic shifting)
   |
   +-- Blue (current) ---- 100% traffic initially
   +-- Green (new)     ---- 0% -> 10% -> 50% -> 100% traffic shift
   |
   v
Primary Region Cluster (GCP/AWS/Azure)
   |
   +-- Continuous backup (etcd snapshot / Velero) --> Object storage
   |
   v
DR Failover Simulation
   |
   v
Secondary Region / Secondary Cloud Cluster (restore from backup)
   |
   v
Cost Optimizer Script (scheduled Lambda/Cloud Function/Azure Function)
   |
   +-- Scans idle resources across clouds --> Slack report --> Auto-cleanup (with approval)
```

## Phase-by-Phase Build

### Phase 1: Security Gates
- Add SAST (SonarQube), container scan (Trivy), and IaC scan (Checkov/tfsec) as mandatory pipeline stages
- Fail the build on Critical/High severity findings, with a documented override process

### Phase 2: Progressive Delivery
- Install Argo Rollouts (or use native traffic splitting: Cloud Run revisions, ECS/CodeDeploy blue-green, Azure Traffic Manager)
- Configure canary steps with automated analysis (error rate, latency) before promoting

### Phase 3: Backup & DR
- Set up Velero (or native backup: GKE Backup, AWS Backup, Azure Backup) for cluster state
- Schedule regular snapshots to object storage (GCS/S3/Blob) with cross-region replication

### Phase 4: DR Failover Drill
- Simulate primary region outage, restore cluster + data to secondary region/cloud
- Document RTO (Recovery Time Objective) and RPO (Recovery Point Objective) actually achieved

### Phase 5: Cost Optimization
- Write a scheduled function that flags idle/oversized resources (unattached disks, oversized node pools, unused load balancers) across at least two clouds
- Report to Slack, with optional auto-remediation behind a manual approval step

## Interview Questions & Debug Scenarios

### Conceptual
- Difference between blue-green and canary deployment strategies — when would you use each?
- What's the difference between RTO and RPO?
- Why scan IaC (Checkov/tfsec) in addition to container images?

### Scenario-Based
- **Q:** A security scan blocks the pipeline on a CVE in a base image you don't control.
  **A:** Triage exploitability (is it network-reachable?), check for a patched tag, apply a temporary allowlist with an expiry date and a tracked ticket, never permanently suppress without review.
- **Q:** Design a zero-downtime deployment and explain rollback mid-rollout.
  **A:** Canary with automated analysis: shift 10% traffic, monitor error rate/latency for N minutes, auto-abort and shift back to 100% blue if thresholds breached — this is what Argo Rollouts automates.
- **Q:** Your primary region goes down — walk through your DR failover.
  **A:** Detect via health checks/alerts -> trigger runbook -> restore latest Velero backup to standby cluster in secondary region -> update DNS/traffic routing -> validate RTO/RPO against target -> post-incident review.
- **Q:** Monthly cloud bill spiked 40% with no obvious usage increase.
  **A:** Check for orphaned resources (unattached disks, idle load balancers, unused snapshots), check autoscaling min/max misconfiguration, check egress traffic costs, use cost anomaly detection tools per cloud.
- **Q:** How do you prevent secrets from leaking through Terraform state files?
  **A:** Use remote encrypted state backends, mark sensitive variables, avoid storing raw secrets in state by referencing Secret Manager/Secrets Manager/Key Vault at runtime instead of embedding values.
- **Q:** A canary deployment passed automated checks but a subtle bug still reached 100% production traffic.
  **A:** Discuss limits of automated analysis (metrics didn't cover the specific failure mode), propose adding business-metric-based analysis, feature flags for fast kill-switch, and better synthetic monitoring pre-promotion.

---

# PRODUCTION READINESS LAYER (Applies to All 5 Projects)

This layer is what separates a "tutorial project" from something you can defend as production-grade in an interview. Apply every item below to Projects 1-5 before calling them "done."

## 1. SLIs, SLOs, and Error Budgets

| Concept | Definition | Example for this portfolio |
|---|---|---|
| SLI | A measured indicator of service health | Request latency (p95), error rate, availability % |
| SLO | Target value for an SLI over a window | 99.5% availability over 30 days, p95 latency < 300ms |
| Error Budget | Allowed unreliability = 1 - SLO | 0.5% budget = ~3.6 hrs downtime/month before freezing risky deploys |

**Interview Q:** "Your team burned 80% of the monthly error budget by day 10 — what do you do?"
**A:** Freeze non-critical deploys, prioritize reliability fixes over features, review recent changes for the root cause of budget burn, communicate risk to stakeholders.

## 2. Capacity Planning

- Load test each tier (Project 2) with k6/Locust before calling it production-ready; record breaking point (requests/sec where p95 latency degrades)
- Document HPA min/max replicas with justification: "min=3 for AZ failure tolerance, max=15 based on load test ceiling"
- Right-size node pools: never run production on a single node pool sized for dev traffic

**Interview Q:** "How did you decide your HPA max replica count isn't just an arbitrary number?"
**A:** Ran load test to find the requests/sec where latency SLO breaks, calculated replicas needed at 2x expected peak traffic with headroom for a rolling deploy.

## 3. Chaos Engineering / Resilience Testing

- Use Chaos Mesh or Litmus on the Project 2/3 cluster to inject: pod kills, network latency, CPU stress, node failure
- Run a "Game Day" once per project: pick a failure mode, inject it, observe via Project 4's Grafana dashboards, document time-to-detect and time-to-recover

**Interview Q:** "Walk me through a chaos experiment you ran and what you learned."
**A:** Describe: hypothesis ("if one pod dies, HPA + readiness probes should reroute traffic with zero user-facing errors") -> injected pod-kill -> observed via dashboard -> found readiness probe delay caused 8 seconds of 502s -> fixed by tuning probe intervals.

## 4. Runbooks / Incident Response

For every project, write at least one runbook in this format:

```
## Runbook: [Incident Name]
**Symptom:** What the alert/user sees
**Likely Causes:** Ranked list
**Diagnostic Steps:** Exact commands to run (kubectl, cloud CLI)
**Resolution Steps:** What to change
**Rollback Plan:** If the fix doesn't work
**Postmortem Owner:** Who writes the retro
```

**Interview Q:** "Do you have on-call experience? How do you triage a 3am page?"
**A:** Even in a home lab: check the alert's linked dashboard first (Project 4), correlate with recent deploys (did something ship in the last hour?), follow the runbook, escalate only if outside your documented playbook — this demonstrates process thinking even without real on-call history.

## 5. Security & Compliance Hardening

| Control | Implementation |
|---|---|
| Least privilege IAM | No wildcard permissions; scoped Workload Identity/IRSA/Managed Identity per workload |
| Secrets management | Never in Git/plaintext; Secret Manager/Secrets Manager/Key Vault + External Secrets Operator |
| Network policy default-deny | Kubernetes NetworkPolicy default-deny-all, explicit allow per tier |
| Image provenance | Sign images (cosign), verify signatures before deploy (admission controller) |
| Audit logging | Enable Cloud Audit Logs/CloudTrail/Azure Activity Log on all projects |
| Pod security | Enforce non-root containers, read-only root filesystem, Pod Security Standards (restricted) |

**Interview Q:** "How do you prove to an auditor that only authorized people deployed to production?"
**A:** Point to Git commit history + PR approvals (GitOps) + ArgoCD sync history + cloud audit logs showing the CI service account (not a human) made the actual API calls.

## 6. Cost Governance

- Tag every resource (project, environment, owner) for cost attribution across GCP/AWS/Azure
- Set budget alerts (Cloud Billing Budgets / AWS Budgets / Azure Cost Alerts) per project
- Review Project 5's cost optimizer output weekly; document at least one real cost fix you made (e.g., "found an idle NAT Gateway costing $32/month, removed it")

**Interview Q:** "Tell me about a time you reduced cloud spend."
**A:** Even in a lab: "I found [specific idle resource] via my cost optimizer script, confirmed it was unused via CloudTrail/audit logs, and removed it — saved $X/month, documented in my cost report."

## 7. CI/CD Maturity Model (Where Does Your Pipeline Sit?)

| Level | Characteristics | Your target by day 60 |
|---|---|---|
| 0 - Manual | SSH + manual deploy | Should be behind you after Project 1 |
| 1 - Basic CI | Build + test automated, manual deploy | Covered by Project 1 |
| 2 - Continuous Delivery | Auto-deploy to non-prod, gated prod | Covered by Project 3 (GitOps) |
| 3 - Continuous Deployment | Auto-deploy to prod with automated rollback | Covered by Project 5 (canary + auto-rollback) |
| 4 - Progressive + Observability-driven | Deploy decisions informed by real-time SLO data | Covered by Project 4 + 5 combined |

**Interview Q:** "What CI/CD maturity level is your current/last team at, and what would you improve?"
**A:** Use this table to self-assess honestly and name one concrete next step — shows critical thinking, not just tool-listing.

## 8. Iterative Learning Log (Fill This In As You Build)

Keep this table updated per project — it becomes your strongest interview asset because it's proof of real iteration, not a one-shot tutorial follow-through.

| Date | Project | What I tried | What broke | Root cause | Fix | What I'd do differently next time |
|---|---|---|---|---|---|---|
| Day 3 | P1 | First CI pipeline | Build succeeded, deploy silently used stale image | Deploying by `:latest` tag | Deploy by commit SHA/digest | Always pin digests from day 1 |
| Day 8 | P1 | Trivy scan gate | Blocked pipeline on unfixable base CVE | No CVE triage process | Added allowlist + expiry + ticket | Set up scan policy before first scan, not after |
| ... | ... | ... | ... | ... | ... | ... |

*(Continue this table for every real issue across all 60 days — aim for 25+ rows total.)*

---

# CROSS-PROJECT INTEGRATION MAP

| Project | Feeds Into | Cloud Services Used (GCP / AWS / Azure) |
|---|---|---|
| 1. Containerize & Deploy | Base image + pipeline reused by 2, 3, 5 | Cloud Run, Cloud Build / ECS Fargate, CodeBuild / Container Apps, Azure Pipelines |
| 2. IaC Kubernetes | Cluster hosts Projects 3, 4 | GKE, VPC / EKS, VPC / AKS, VNet |
| 3. GitOps Microservices | Instrumented by Project 4 | ArgoCD on GKE/EKS/AKS |
| 4. OTel + Grafana | Monitors 1, 2, 3, 5 | Cloud Monitoring / CloudWatch / Azure Monitor (as secondary data sources) |
| 5. DevSecOps + DR | Wraps security/DR/cost around all | Cloud Armor, Backup / GuardDuty, AWS Backup / Defender for Cloud, Azure Backup |

---

# 60-DAY EXECUTION TIMELINE

| Days | Project | Primary Cloud | Key Milestone |
|---|---|---|---|
| 1-12 | Project 1 | GCP | CI/CD live, 5 documented debug incidents |
| 13-24 | Project 2 | AWS | EKS cluster via Terraform, RBAC + Ingress working |
| 25-36 | Project 3 | Azure | ArgoCD multi-env GitOps, rollback tested |
| 37-48 | Project 4 | GCP (cross-cloud federation) | OTel + Grafana LGTM stack monitoring all prior projects |
| 49-58 | Project 5 | AWS + Azure combined | Security gate, blue-green deploy, DR drill completed |
| 59-60 | Mock Interviews | All three | Full scenario walkthroughs across GCP/AWS/Azure |

**Rule of thumb:** document 5+ real troubleshooting incidents per project (25+ total) with exact error message, root cause, and fix — this is the difference between reciting theory and telling a credible production story in interviews.


---

# APPENDIX: SYSTEM DESIGN & BEHAVIORAL QUESTIONS (Cross-Project)

## System Design Style Questions
- "Design the entire CI/CD + deployment pipeline for a company with 20 microservices across 3 environments." (Tie together Projects 1, 3, 5)
- "How would you architect this same 3-tier app to survive a full region outage with under 5 minutes of downtime?" (Tie together Projects 2, 5)
- "A new team joins and wants to onboard 5 new services onto your platform in a week — how do you make that possible?" (Answer: templated Helm charts, App-of-Apps pattern, self-service golden path from Project 3)
- "How do you decide between Kubernetes and serverless (Cloud Run/Fargate/Container Apps) for a new service?" (Trade-off discussion: cold starts, cost at scale, operational overhead)

## Behavioral / STAR-Format Questions (Use Your Learning Log)
- "Tell me about a production incident you handled." — Pull directly from your Iterative Learning Log table.
- "Describe a time you had to make a trade-off between speed and reliability." — Reference canary rollout thresholds from Project 5.
- "How do you stay current with DevOps tools and practices?" — Reference building this exact multi-cloud portfolio and the specific tools you evaluated (OTel vs Prometheus-only, Mimir vs Prometheus, etc.)
- "Describe a disagreement you had about a technical approach and how it was resolved." — Use the "teammate wants direct DB access from web tier" scenario from Project 2 as a template, framed as something you'd push back on.

## Final Pre-Interview Checklist
- [ ] Every project has a live (or easily re-launchable) demo
- [ ] Every project's README includes the architecture diagram from this doc
- [ ] Iterative Learning Log has 25+ real entries
- [ ] You can whiteboard the 3-tier network diagram from memory
- [ ] You can explain trace-to-log-to-metric correlation live in Grafana
- [ ] You can state your SLOs and current error budget status for at least one project
- [ ] You have at least one cost-saving story and one security-hardening story ready
- [ ] You have run at least one chaos experiment and can describe the outcome
