# Project 2: IaC Kubernetes Cluster (GCP GKE 3-Tier Architecture Dedicated)

This guide provides a production-grade, end-to-end implementation of **Project 2** for Google Cloud Platform (GCP). Building directly upon **Phase 1** (where we containerized the Node.js application and published images to GCP Artifact Registry), **Phase 2** incorporates the Phase 1 application source code, enhances it with Cloud SQL database connectivity, and deploys it into a full production-ready 3-Tier Architecture on **Google Kubernetes Engine (GKE)** using **Terraform (IaC)**, **Cloud SQL (PostgreSQL)**, **Cloud Armor (WAF)**, **Workload Identity**, and eBPF-based **NetworkPolicies**.

---

## 1. Architecture Flow & Continuation from Phase 1

### How Phase 1 Feeds into Phase 2
In Phase 1, we built an optimized container image (`$REGION-docker.pkg.dev/$PROJECT_ID/devops-portfolio/app:latest`) and deployed it to Cloud Run. In Phase 2, we take that same application code, enhance `server.js` with PostgreSQL database capabilities, package it via Docker & Cloud Build, and deploy it inside a **3-Tier Production GKE Cluster** provisioned via **Terraform**.

```
                                    INTERNET
                                       │
                                       ▼
                       ┌──────────────────────────────┐
                       │ GCP Cloud Armor (WAF at Edge)│
                       └──────────────┬───────────────┘
                                      │
                                      ▼
             ┌──────────────────────────────────────────────────┐
             │ GCP Cloud Load Balancing (External HTTP/S Ingress)│
             └──────────────┬───────────────────────────────────┘
                            │
  ┌─────────────────────────┴─────────────────────────────────────────┐
  │ GCP VPC (10.0.0.0/16)                                             │
  │                                                                   │
  │  ┌────────────────────────────────────────────────────────┐       │
  │  │ PUBLIC / WEB SUBNET (10.0.1.0/24)                      │       │
  │  │ Tier 1: Presentation Layer                             │       │
  │  │  - Nginx Ingress / Frontend Pods                       │       │
  │  │  - NetworkPolicy: Ingress from LB, Egress to Tier 2    │       │
  │  └────────────────────────┬───────────────────────────────┘       │
  │                           │ (Private ClusterIP on Port 8080)      │
  │                           ▼                                       │
  │  ┌────────────────────────────────────────────────────────┐       │
  │  │ PRIVATE / APP SUBNET (10.0.2.0/24)                     │       │
  │  │ Tier 2: Application Layer (GKE Private Node Pool)     │       │
  │  │  - Node.js API Pods (Phase 1 Code + PG Client)        │       │
  │  │  - Workload Identity bound to GCP IAM Service Account  │       │
  │  │  - Cloud SQL Auth Proxy Sidecar (127.0.0.1:5432)       │       │
  │  │  - NetworkPolicy: Ingress from Tier 1 ONLY             │       │
  │  │  - NetworkPolicy: Egress to Tier 3 (Cloud SQL) ONLY    │       │
  │  └────────────────────────┬───────────────────────────────┘       │
  │                           │ (Private Service Access / VPC Peering)│
  │                           ▼                                       │
  │  ┌────────────────────────────────────────────────────────┐       │
  │  │ PRIVATE DATA SUBNET / PSA RANGE (10.0.3.0/24)          │       │
  │  │ Tier 3: Database Layer                                 │       │
  │  │  - Managed GCP Cloud SQL (PostgreSQL - Private IP)     │       │
  │  │  - NO Public IP | NO Internet Egress Route             │       │
  │  │  - Firewall / PSA: Ingress from Tier 2 App Subnet ONLY │       │
  │  └────────────────────────────────────────────────────────┘       │
  └───────────────────────────────────────────────────────────────────┘
```

---

## 2. Directory Structure

Phase 2 contains the application source code from Phase 1, the Terraform infrastructure code, and the Kubernetes manifests:

```
project-2/
├── app/
│   ├── package.json
│   ├── server.js
│   ├── Dockerfile
│   └── .dockerignore
├── cloudbuild.yaml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── gke.tf
│   ├── cloudsql.tf
│   ├── iam.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── k8s/
    ├── 00-namespaces-rbac.yaml
    ├── 01-network-policies.yaml
    ├── 02-tier1-frontend.yaml
    ├── 03-tier2-backend.yaml
    ├── 04-hpa-autoscaling.yaml
    └── ingress-cloudarmor.yaml
```

---

## 3. Detailed GCP Architectural Analysis

Before deploying, master these 6 core GCP & GKE production architecture concepts:

### Deep Dive 1: VPC-Native Clusters (Alias IP) & Subnet Segmentation
- **Why VPC-Native?** Standard route-based clusters use custom static routes that limit scale. GKE VPC-native clusters allocate Pod IP addresses directly from secondary IP ranges in the GCP VPC. This enables native routing, improved performance, direct connectivity to Cloud SQL via Private Service Access, and enhanced Cloud Armor / VPC Firewall visibility.
- **3-Tier Subnet Layout:**
  - `web-subnet` (`10.0.1.0/24`): Holds public ingress entrypoints.
  - `app-subnet` (`10.0.2.0/24`): Houses GKE private worker nodes (`10.0.2.0/24`), Pod secondary range (`10.100.0.0/16`), and Service secondary range (`10.101.0.0/20`). No public IPs on nodes.
  - `data-subnet` / Private Service Connection (`10.0.3.0/24`): Allocated for GCP Private Service Access (PSA) to host Cloud SQL private endpoints.

### Deep Dive 2: GKE Private Cluster & Control Plane Security
- **Private Nodes:** GKE worker nodes have internal IP addresses only. Outbound internet access (e.g. pulling Docker images from Artifact Registry or downloading OS patches) is routed strictly through a **Cloud NAT** gateway.
- **Master Authorized Networks:** The Kubernetes API control plane (`https://[MASTER_IP]`) is restricted to specific CIDR blocks (e.g., corporate VPN or bastion host IP). Public access to the API server is completely disabled or blocked by IP filters.

### Deep Dive 3: GCP Workload Identity (Keyless IAM Authentication)
- **The Problem:** Storing GCP IAM service account JSON keys inside Kubernetes Secrets risks credential leaks.
- **The Solution:** Workload Identity maps a Kubernetes Service Account (`KSA`) in a specific namespace to a Google IAM Service Account (`GSA`).
- **How it Works:** When a pod using the KSA makes a Google Cloud API call, the GKE Metadata Server intercepts the request, exchanges the Kubernetes OIDC token for a short-lived GCP OAuth2 access token, allowing seamless, secure authentication to Cloud SQL, Secret Manager, or Artifact Registry without static keys.

### Deep Dive 4: Tier 3 Isolation with Private Service Access & Cloud SQL Auth Proxy
- **Private Service Access (PSA):** A private VPC peering connection between your VPC and Google's internal service producer network. Cloud SQL receives a private IP (`10.0.3.x`) inside your VPC.
- **Cloud SQL Auth Proxy:** Instead of storing raw DB passwords or opening direct database ports across subnets, Tier 2 App pods run a `cloud-sql-proxy` sidecar container. The app connects to `127.0.0.1:5432` locally; the proxy secures the connection to Cloud SQL over an mTLS tunnel authenticated via Workload Identity.

### Deep Dive 5: Zero-Trust NetworkPolicies with GKE Dataplane V2 (eBPF)
- GKE Dataplane V2 uses **eBPF (Extended Berkeley Packet Filter)** in the Linux kernel rather than legacy `iptables`.
- It enforces micro-segmentation:
  - **Default Deny All:** All ingress and egress traffic in the namespace is denied by default.
  - **Tier 1 -> Tier 2 Rule:** Frontend pods can send HTTP requests to Tier 2 API pods on port `8080`.
  - **Tier 2 -> Tier 3 Rule:** App pods can only send egress traffic to Cloud SQL (`10.0.3.x:5432`).
  - **Tier 1 -> Tier 3 Denial:** Direct network routes between Tier 1 and Tier 3 are strictly blocked.

### Deep Dive 6: GKE Ingress & Cloud Armor (Edge WAF)
- GKE Container-Native Load Balancing uses `NetworkEndpointGroups` (NEGs) to route HTTP requests directly from the GCP External HTTP(S) Load Balancer into individual Pod IPs (skipping `kube-proxy` NodePort hops).
- **Cloud Armor** attaches security policies at the load balancer edge to filter SQL Injection (SQLi), Cross-Site Scripting (XSS), DDoS attacks, and IP blacklist ranges before traffic reaches GKE nodes.

---

## 4. Implementation Code

### A. Application Code (Phase 1 Baseline + Phase 2 PostgreSQL Integration)

#### File: `project-2/app/package.json`
```json
{
  "name": "gcp-devops-p2-app",
  "version": "2.0.0",
  "description": "Production Node.js API with Cloud SQL PostgreSQL integration for GKE 3-Tier Architecture",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "test": "jest --passWithNoTests",
    "lint": "eslint ."
  },
  "dependencies": {
    "express": "^4.19.2",
    "pg": "^8.11.5"
  },
  "devDependencies": {
    "eslint": "^8.57.0",
    "jest": "^29.7.0",
    "supertest": "^6.3.4"
  }
}
```

#### File: `project-2/app/server.js`
```javascript
const express = require('express');
const { Pool } = require('pg');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// PostgreSQL Connection Pool connecting to Cloud SQL Auth Proxy sidecar (127.0.0.1:5432)
const pool = new Pool({
  host: process.env.DB_HOST || '127.0.0.1',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME || 'appdb',
  user: process.env.DB_USER || 'appuser',
  password: process.env.DB_PASS || 'password',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// Phase 1 Baseline Welcome Endpoint
app.get('/', (req, res) => {
  res.json({
    status: "Healthy",
    message: "Welcome to Project 2 (GKE 3-Tier Architecture) on GCP!",
    timestamp: new Date(),
    version: process.env.K_REVISION || "2.0.0",
    tier: "Tier 2 Application API"
  });
});

// Explicit health check endpoint for GKE probes
app.get('/health', (req, res) => {
  res.status(200).json({ status: "UP", tier: "Tier 2" });
});

// Phase 2 Database Health Check (Verifies Tier 2 -> Tier 3 Cloud SQL connectivity)
app.get('/db-health', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW() as db_time, current_database() as db_name');
    res.status(200).json({
      status: "CONNECTED",
      database: result.rows[0].db_name,
      timestamp: result.rows[0].db_time
    });
  } catch (err) {
    console.error('Database connection error:', err.message);
    res.status(500).json({
      status: "DISCONNECTED",
      error: err.message
    });
  }
});

// Phase 2 Data Endpoint
app.get('/api/items', async (req, res) => {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS items (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    const result = await pool.query('SELECT * FROM items ORDER BY id DESC LIMIT 10');
    res.json({ success: true, count: result.rowCount, data: result.rows });
  } catch (err) {
    console.error('API Query error:', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`Phase 2 Application API listening on port ${PORT}`);
});

module.exports = server;
```

#### File: `project-2/app/Dockerfile`
```dockerfile
# Stage 1: Build & Package Dependencies
FROM node:20-alpine AS builder
WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Runtime Release
FROM node:20-alpine
WORKDIR /usr/src/app

# Security Hardening: Upgrade OS libraries to patch CVEs
RUN apk update && apk upgrade --no-cache

# Run as non-root user
USER node

# Copy dependencies and source code from Stage 1 builder
COPY --chown=node:node --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=node:node . .

# Set environment variables
ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
```

#### File: `project-2/app/.dockerignore`
```ignore
node_modules
npm-debug.log
.git
.github
.gitignore
Dockerfile
cloudbuild.yaml
.env
```

#### File: `project-2/cloudbuild.yaml`
```yaml
steps:
  # 1. Install Dependencies & Run Tests/Linting
  - name: 'node:20-alpine'
    entrypoint: 'npm'
    args: ['install']
    dir: 'project-2/app'
    id: 'Install Dev Dependencies'

  - name: 'node:20-alpine'
    entrypoint: 'npm'
    args: ['run', 'test']
    dir: 'project-2/app'
    id: 'Run Unit Tests'

  # 2. Build Container Image targeting Artifact Registry
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-t'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app-p2:$_IMAGE_TAG'
      - './project-2/app'
    id: 'Build Container'

  # 3. Security Vulnerability Scan using Trivy
  - name: 'aquasec/trivy:latest'
    args:
      - 'image'
      - '--exit-code'
      - '1'
      - '--severity'
      - 'CRITICAL'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app-p2:$_IMAGE_TAG'
    id: 'Security Vulnerability Scan'

  # 4. Push Container Image to Google Artifact Registry
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'push'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app-p2:$_IMAGE_TAG'
    id: 'Push to Artifact Registry'

  # 5. Deploy / Rolling Update to GKE Cluster
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        gcloud container clusters get-credentials $_GKE_CLUSTER_NAME --region $_DEPLOY_REGION --project $PROJECT_ID
        kubectl set image deployment/backend-deployment api-app=$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app-p2:$_IMAGE_TAG --namespace=default
        kubectl rollout status deployment/backend-deployment --namespace=default
    id: 'Deploy Rolling Update to GKE'

substitutions:
  _GAR_REGION: 'us-central1'
  _GAR_REPO: 'devops-portfolio'
  _GKE_CLUSTER_NAME: 'gke-3tier-prod'
  _DEPLOY_REGION: 'us-central1'
  _IMAGE_TAG: 'latest'

images:
  - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app-p2:$_IMAGE_TAG'

options:
  logging: CLOUD_LOGGING_ONLY
```

---

### B. Infrastructure as Code (Terraform)

#### File: `phase2/terraform/variables.tf`
```hcl
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for resources"
  type        = string
  default     = "us-east4"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "gke-3tier-prod"
}

variable "authorized_ipv4_cidr" {
  description = "CIDR block authorized to access GKE Master API"
  type        = string
  default     = "0.0.0.0/0"
}
```

#### File: `phase2/terraform/vpc.tf`
```hcl
# VPC Network for 3-Tier Production Architecture
resource "google_compute_network" "vpc" {
  name                    = "vpc-3tier-prod"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Tier 1: Public / Web Subnet
resource "google_compute_subnetwork" "web_subnet" {
  name          = "sb-web-us-east4"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Tier 2: Private / App Subnet (VPC-Native GKE Cluster)
resource "google_compute_subnetwork" "app_subnet" {
  name                     = "sb-app-us-east4"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.100.0.0/16"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.101.0.0/20"
  }
}

# Cloud Router & NAT for Private GKE Worker Nodes outbound egress
resource "google_compute_router" "router" {
  name    = "router-3tier"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-3tier"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Private Service Access IP Allocation for Tier 3 Cloud SQL
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "psa-cloudsql-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

# VPC Peering Connection for Private Service Access
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}
```

#### File: `phase2/terraform/gke.tf`
```hcl
resource "google_container_cluster" "gke_cluster" {
  name                = var.cluster_name
  location            = "${var.region}-a"
  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.app_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.authorized_ipv4_cidr
      display_name = "Admin Authorized CIDR"
    }
  }

  datapath_provider = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_container_node_pool" "app_nodes" {
  name       = "np-app-tier"
  location   = var.region
  cluster    = google_container_cluster.gke_cluster.name
  node_count = 2

  autoscaling {
    min_node_count = 2
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-2"
    spot         = false
    disk_size_gb = 50
    disk_type    = "pd-standard"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    service_account = google_service_account.gke_node_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      tier = "app"
    }

    tags = ["gke-node", "app-tier"]
  }
}
```

#### File: `project-2/terraform/cloudsql.tf`
```hcl
resource "random_password" "db_password" {
  length  = 16
  special = false
}

resource "google_sql_database_instance" "postgres" {
  name             = "cloudsql-3tier-db"
  database_version = "POSTGRES_15"
  region           = var.region

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }
  }

  deletion_protection = false
}

resource "google_sql_database" "database" {
  name     = "appdb"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "db_user" {
  name     = "appuser"
  instance = google_sql_database_instance.postgres.name
  password = random_password.db_password.result
}
```

#### File: `project-2/terraform/iam.tf`
```hcl
resource "google_service_account" "gke_node_sa" {
  account_id   = "sa-gke-nodes"
  display_name = "GKE Node Pool Service Account"
}

resource "google_project_iam_member" "node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "node_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_service_account" "app_workload_sa" {
  account_id   = "sa-app-backend"
  display_name = "Service Account for App Backend Workload Identity"
}

resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app_workload_sa.email}"
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.app_workload_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/ksa-app-backend]"

  depends_on = [google_container_cluster.gke_cluster]
}
```

#### File: `phase2/terraform/outputs.tf`
```hcl
output "gke_cluster_name" {
  value = google_container_cluster.gke_cluster.name
}

output "gke_get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.gke_cluster.name} --zone ${var.region}-a --project ${var.project_id}"
}

output "cloudsql_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "cloudsql_connection_name" {
  value = google_sql_database_instance.postgres.connection_name
}

output "db_password" {
  value     = random_password.db_password.result
  sensitive = true
}
```

---

### C. Kubernetes Manifests (3-Tier & Security Isolation)

#### File: `project-2/k8s/00-namespaces-rbac.yaml`
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ksa-app-backend
  namespace: default
  annotations:
    iam.gke.io/gcp-service-account: "sa-app-backend@PROJECT_ID.iam.gserviceaccount.com"
```

#### File: `project-2/k8s/01-network-policies.yaml`
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-tier1-frontend
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: frontend
      tier: tier1
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - {}
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
              tier: tier2
      ports:
        - protocol: TCP
          port: 8080
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-tier2-backend
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: backend
      tier: tier2
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
              tier: tier1
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.3.0/24
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

#### File: `project-2/k8s/02-tier1-frontend.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-deployment
  namespace: default
  labels:
    app: frontend
    tier: tier1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
      tier: tier1
  template:
    metadata:
      labels:
        app: frontend
        tier: tier1
    spec:
      containers:
        - name: nginx-frontend
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
  namespace: default
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app: frontend
    tier: tier1
  ports:
    - port: 80
      targetPort: 80
```

#### File: `project-2/k8s/03-tier2-backend.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
  namespace: default
  labels:
    app: backend
    tier: tier2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
      tier: tier2
  template:
    metadata:
      labels:
        app: backend
        tier: tier2
    spec:
      serviceAccountName: ksa-app-backend
      containers:
        - name: api-app
          image: REGION-docker.pkg.dev/PROJECT_ID/devops-portfolio/app-p2:latest
          env:
            - name: PORT
              value: "8080"
            - name: DB_HOST
              value: "127.0.0.1"
            - name: DB_PORT
              value: "5432"
            - name: DB_NAME
              value: "appdb"
            - name: DB_USER
              value: "appuser"
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10

        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.8.1
          args:
            - "--structured-logs"
            - "--port=5432"
            - "PROJECT_ID:REGION:cloudsql-3tier-db"
          securityContext:
            runAsNonRoot: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend-service
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: backend
    tier: tier2
  ports:
    - port: 8080
      targetPort: 8080
```

#### File: `phase2/k8s/04-hpa-autoscaling.yaml`
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

#### File: `phase2/k8s/05-production-ingress.yaml`
```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: frontend-backend-config
  namespace: default
spec:
  timeoutSec: 40
  connectionDraining:
    drainingTimeoutSec: 60
  logging:
    enable: true
    sampleRate: 1.0
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gke-prod-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "gke-frontend-static-ip"
spec:
  defaultBackend:
    service:
      name: frontend-service
      port:
        number: 80
  rules:
    - http:
        paths:
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

---

## 5. End-to-End Implementation & Execution Steps

### Step 1: Initialize GCP Environment & Enable APIs
```bash
export PROJECT_ID=$(gcloud config get-value project)
export REGION="us-east4"
export REPO_NAME="devops-portfolio"

gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  servicenetworking.googleapis.com \
  sqladmin.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com
```

### Step 2: Build Application Image & Push to Artifact Registry
```bash
# Submit build using project-2/cloudbuild.yaml
gcloud builds submit --config=project-2/cloudbuild.yaml \
  --substitutions=_GAR_REGION=$REGION,_GAR_REPO=$REPO_NAME,_GKE_CLUSTER_NAME=gke-3tier-prod,_DEPLOY_REGION=$REGION
```

### Step 3: Provision Infrastructure with Terraform
```bash
cd project-2/terraform

cat <<EOF > terraform.tfvars
project_id = "${PROJECT_ID}"
region     = "${REGION}"
EOF

terraform init
terraform plan -out=tfplan
terraform apply tfplan -auto-approve
```

### Step 4: Configure `kubectl` Credentials
```bash
# Get cluster credentials outputted by Terraform
$(terraform output -raw gke_get_credentials_command)

# Verify cluster nodes are ready
kubectl get nodes -o wide
```

### Step 5: Configure Database Secrets & Apply Kubernetes Manifests
```bash
# Extract DB password from Terraform sensitive outputs
DB_PASSWORD=$(terraform output -raw db_password)

cd ../k8s

# Create K8s secret for DB password
kubectl create secret generic db-credentials \
  --from-literal=password="${DB_PASSWORD}"

# Replace placeholder variables in manifests
sed -i "s/PROJECT_ID/${PROJECT_ID}/g" 00-namespaces-rbac.yaml
sed -i "s/PROJECT_ID/${PROJECT_ID}/g" 03-tier2-backend.yaml
sed -i "s/REGION/${REGION}/g" 03-tier2-backend.yaml

# Deploy K8s resources
kubectl apply -f 00-namespaces-rbac.yaml
kubectl apply -f 01-network-policies.yaml
kubectl apply -f 02-tier1-frontend.yaml
kubectl apply -f 03-tier2-backend.yaml
kubectl apply -f 04-hpa-autoscaling.yaml
```

### Step 6: Verify 3-Tier Security Segmentation & Database Connectivity
```bash
# 1. Check Pod status across tiers
kubectl get pods -l tier=tier1
kubectl get pods -l tier=tier2

# 2. Test Tier 1 -> Tier 2 HTTP Communication (ALLOWED)
FRONTEND_POD=$(kubectl get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $FRONTEND_POD -- wget -qO- http://backend-service:8080/health

# 3. Test Tier 2 -> Tier 3 Database Connectivity (CONNECTED)
BACKEND_POD=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $BACKEND_POD -c api-app -- wget -qO- http://localhost:8080/db-health

# 4. Test Tier 1 -> Tier 3 Cloud SQL Direct Access (MUST BE BLOCKED by NetworkPolicy)
CLOUDSQL_IP=$(cd ../terraform && terraform output -raw cloudsql_private_ip)
kubectl exec -it $FRONTEND_POD -- nc -zv -w 3 $CLOUDSQL_IP 5432 || echo "Tier 1 -> Tier 3 correctly BLOCKED!"
```

---

## 6. "Break & Learn" Test Cases (Interactive Interview Debugging Lab)

Use these 11 interactive debugging scenarios to simulate real-world GKE production incidents, observe failure symptoms, and master root-cause resolution.

```bash
# Helper: Export common variables for the lab
export PROJECT_ID=$(gcloud config get-value project)
export REGION="us-east4"
export ZONE="us-east4-a"
```

---

### Case 1: Workload Identity IAM Binding & Placeholder Mismatch
> [!WARNING]
> **Interview Context:** "Your application pod deploys and runs, but the Cloud SQL Auth Proxy sidecar crashes continuously with `google: could not find default credentials` or `403 Forbidden` on the Cloud SQL API."

* **How to Break:**
  ```bash
  # Scenario A: Overwrite KSA annotation with an un-substituted template placeholder
  kubectl annotate serviceaccount ksa-app-backend --overwrite \
    iam.gke.io/gcp-service-account="sa-app-backend@PROJECT_ID.iam.gserviceaccount.com"

  # Trigger pod restart to flush cached tokens
  kubectl rollout restart deployment backend-deployment
  ```
  *(Or Scenario B: Remove the GCP IAM Workload Identity binding)*
  ```bash
  gcloud iam service-accounts remove-iam-policy-binding \
    sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[default/ksa-app-backend]"
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Pod Ready Status & Restarts:**
     ```bash
     kubectl get pods -l app=backend
     # Expected Output: STATUS: CrashLoopBackOff | READY: 1/2 | RESTARTS: >= 1
     ```
  2. **Inspect Container Status Details:**
     ```bash
     kubectl get pod -l app=backend -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{"\tReady: "}{.ready}{"\tRestarts: "}{.restartCount}{"\tState: "}{.state}{"\n"}{end}'
     # Expected Output: cloud-sql-proxy Ready: false, waiting (CrashLoopBackOff)
     ```
  3. **Read Crash Logs from Previous Container Run:**
     ```bash
     BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
     kubectl logs $BACKEND_POD -c cloud-sql-proxy --previous --tail=30
     ```
     *Expected Error Signature:*
     ```text
     {"severity":"INFO","message":"Authorizing with Application Default Credentials"}
     {"severity":"ERROR","message":"The proxy has encountered a terminal error: unable to start: error initializing dialer: failed to create token source: google: could not find default credentials."}
     ```
  4. **Verify ServiceAccount Annotation & IAM Policy:**
     ```bash
     # Check live KSA annotation
     kubectl get sa ksa-app-backend -o yaml | grep iam.gke.io
     # Notice literal "PROJECT_ID" instead of real project ID!

     # Check GCP IAM Policy Binding
     gcloud iam service-accounts get-iam-policy sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com
     ```

* **The Learn (Root Cause Analysis):**
  Without the `roles/iam.workloadIdentityUser` IAM binding and a valid `iam.gke.io/gcp-service-account` annotation containing the real GCP project ID, the GKE Metadata Server emulator rejects token exchange attempts from the KSA. The sidecar fails to receive Google Application Default Credentials (ADC) and crashes immediately with Exit Code 1.

* **How to Fix:**
  ```bash
  # 1. Update KSA annotation with real GCP project ID
  kubectl annotate serviceaccount ksa-app-backend --overwrite \
    iam.gke.io/gcp-service-account="sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com"

  # 2. Ensure GCP IAM Workload Identity user binding exists
  gcloud iam service-accounts add-iam-policy-binding \
    sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[default/ksa-app-backend]"

  # 3. Rollout restart the deployment
  kubectl rollout restart deployment backend-deployment
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl rollout status deployment backend-deployment
  kubectl get pods -l app=backend
  # Expected: READY 2/2 | STATUS Running | RESTARTS 0
  ```

---

### Case 2: NetworkPolicy Egress Drop (Tier 1 -> Tier 2 HTTP 504 Timeout)
> [!WARNING]
> **Interview Context:** "Frontend pods return `504 Gateway Timeout` when making API requests to the backend service. Both sets of pods are reported as `Running`. Where is the failure?"

* **How to Break:**
  Modify `01-network-policies.yaml` to change the allowed egress port in `allow-tier1-frontend` from `8080` to `9090`, then apply it:
  ```yaml
  # In 01-network-policies.yaml -> allow-tier1-frontend
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
              tier: tier2
      ports:
        - protocol: TCP
          port: 9090 # Wrong port breaking Tier 1 -> Tier 2 traffic
  ```
  ```bash
  kubectl apply -f phase2/k8s/01-network-policies.yaml
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Pod Health (Both appear deceptively healthy!):**
     ```bash
     kubectl get pods -o wide
     # Both frontend and backend show Running (1/1 and 2/2)
     ```
  2. **Execute Inter-Tier HTTP Request from Frontend Pod:**
     ```bash
     FRONTEND_POD=$(kubectl get pods -l app=frontend -o jsonpath='{.items[0].metadata.name}')
     kubectl exec -it $FRONTEND_POD -- wget -T 5 -qO- http://backend-service:8080/health
     # Expected Error: wget: download timed out
     ```
  3. **Inspect Active NetworkPolicies:**
     ```bash
     kubectl describe netpol allow-tier1-frontend
     # Look at Egress rules: notice allowed port is 9090 while backend-service listens on 8080!
     ```

* **The Learn (Root Cause Analysis):**
  GKE Dataplane V2 (Cilium eBPF) compiles NetworkPolicies directly into Linux kernel socket filters. If an egress packet's destination port (`8080`) does not match the active whitelist, the kernel silently drops the packet. The frontend TCP socket hangs until client-side timeout occurs.

* **How to Fix:**
  Restore port `8080` in `phase2/k8s/01-network-policies.yaml`:
  ```yaml
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
              tier: tier2
      ports:
        - protocol: TCP
          port: 8080
  ```
  ```bash
  kubectl apply -f phase2/k8s/01-network-policies.yaml
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl exec -it $FRONTEND_POD -- wget -qO- http://backend-service:8080/health
  # Expected Response: {"status":"UP","tier":"Tier 2"}
  ```

---

### Case 3: Private Service Access (PSA) IP Space Exhaustion
> [!WARNING]
> **Interview Context:** "When running `terraform apply` to provision a new Cloud SQL instance in an existing VPC, Terraform fails with `IP_SPACE_EXHAUSTED` or `Failed to allocate IP range`."

* **How to Break:**
  In `phase2/terraform/vpc.tf`, define the PSA global IP prefix length as `/29` (only 8 IP addresses) instead of `/20`:
  ```hcl
  resource "google_compute_global_address" "private_ip_alloc" {
    name          = "psa-cloudsql-ip-range"
    purpose       = "VPC_PEERING"
    address_type  = "INTERNAL"
    prefix_length = 29 # Too small!
    network       = google_compute_network.vpc.id
  }
  ```

* **What to Check & Diagnostic Commands:**
  1. **Run Terraform Apply & Observe Output:**
     ```bash
     cd phase2/terraform && terraform apply -auto-approve
     ```
     *Expected Error:*
     ```text
     Error: Error creating DatabaseInstance: googleapi: Error 400: The network has no available IP space for Private Service Access allocation. IP_SPACE_EXHAUSTED.
     ```
  2. **Inspect Reserved Peering Ranges via gcloud:**
     ```bash
     gcloud compute addresses list --global --filter="purpose=VPC_PEERING"
     # Notice address prefix length is /29 (insufficient for tenant VPC subnets)
     ```

* **The Learn (Root Cause Analysis):**
  Google Cloud Service Networking allocates internal subnets, routing tables, and HA standby nodes inside Google's managed Tenant project. A minimum prefix of `/24` (256 IPs) or `/20` (4,096 IPs) is required for Cloud SQL, Redis, and future expansion.

* **How to Fix:**
  Update `phase2/terraform/vpc.tf` with `prefix_length = 20`:
  ```hcl
  resource "google_compute_global_address" "private_ip_alloc" {
    name          = "psa-cloudsql-ip-range"
    purpose       = "VPC_PEERING"
    address_type  = "INTERNAL"
    prefix_length = 20
    network       = google_compute_network.vpc.id
  }
  ```
  ```bash
  terraform apply -auto-approve
  ```

* **Verification (How to Confirm Success):**
  ```bash
  gcloud compute addresses describe psa-cloudsql-ip-range --global --format="value(address,prefixLength)"
  # Expected: 10.230.160.0, 20
  ```

---

### Case 4: GKE Master Authorized Networks Blocking `kubectl`
> [!WARNING]
> **Interview Context:** "A developer on your team attempts to run `kubectl get pods` from their machine and receives `Unable to connect to the server: dial tcp [IP]:443: i/o timeout`."

* **How to Break:**
  Lock the master authorized network to a non-routable dummy IP (`192.0.2.1/32`):
  ```bash
  gcloud container clusters update gke-3tier-prod \
    --zone us-east4-a \
    --enable-master-authorized-networks \
    --master-authorized-networks 192.0.2.1/32
  ```

* **What to Check & Diagnostic Commands:**
  1. **Execute Any kubectl Command:**
     ```bash
     kubectl get pods
     ```
     *Expected Error:*
     ```text
     Unable to connect to the server: dial tcp 10.0.2.x:443: i/o timeout
     # or
     Error from server (Forbidden): client IP "X.X.X.X" is not authorized to access master
     ```
  2. **Inspect Authorized Network Configuration:**
     ```bash
     gcloud container clusters describe gke-3tier-prod --zone us-east4-a \
       --format="yaml(masterAuthorizedNetworksConfig)"
     ```

* **The Learn (Root Cause Analysis):**
  GKE Master Authorized Networks injects Google Cloud perimeter firewall rules directly in front of the managed `kube-apiserver` endpoint. Any client IP address outside the authorized list is dropped at the GCP edge before reaching TLS handshake.

* **How to Fix:**
  Detect your current public IP address and whitelist it:
  ```bash
  MY_IP="$(curl -s ifconfig.me)/32"
  gcloud container clusters update gke-3tier-prod \
    --zone us-east4-a \
    --enable-master-authorized-networks \
    --master-authorized-networks ${MY_IP}
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl get nodes
  # Expected: All worker nodes return status Ready
  ```

---

### Case 5: Container Cold-Start & Memory Limits / OOMKills (Exit Code 137)
> [!WARNING]
> **Interview Context:** "Under heavy traffic, GKE pods randomly disappear and restart with status `OOMKilled`, while cluster nodes show low total memory utilization."

* **How to Break:**
  Set an unrealistically low memory limit (`32Mi`) in `phase2/k8s/03-tier2-backend.yaml`:
  ```yaml
  resources:
    requests:
      cpu: 100m
      memory: 16Mi
    limits:
      cpu: 200m
      memory: 32Mi # Node.js V8 runtime baseline memory is ~60-100Mi
  ```
  ```bash
  kubectl apply -f phase2/k8s/03-tier2-backend.yaml
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Pod Restarts & Status:**
     ```bash
     kubectl get pods -l app=backend
     # Expected: STATUS: OOMKilled or CrashLoopBackOff | RESTARTS increasing
     ```
  2. **Inspect Pod Termination Reason:**
     ```bash
     BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
     kubectl describe pod $BACKEND_POD | grep -A 5 "Last State"
     ```
     *Expected Output:*
     ```text
     Last State:     Terminated
       Reason:       OOMKilled
       Exit Code:    137
     ```

* **The Learn (Root Cause Analysis):**
  When a container process allocates more physical memory than its Cgroup `limits.memory` threshold, the Linux kernel Out-Of-Memory (OOM) killer sends `SIGKILL` (`kill -9`, Exit Code $128 + 9 = 137$). The node may have 80% free memory, but the container Cgroup boundary is strictly enforced.

* **How to Fix:**
  Right-size memory requests and limits in `phase2/k8s/03-tier2-backend.yaml`:
  ```yaml
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  ```
  ```bash
  kubectl apply -f phase2/k8s/03-tier2-backend.yaml
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl top pod -l app=backend
  # Expected: Active memory utilization displayed well below 512Mi limit
  ```

---

### Case 6: Missing Container-Native NEG Annotation (Ingress 502 Bad Gateway)
> [!WARNING]
> **Interview Context:** "You deployed a GKE Ingress object backed by a ClusterIP service, but the Google Cloud HTTP(S) Load Balancer health checks fail consistently, returning `502 Server Error`."

* **How to Break:**
  Remove the NEG annotation from `phase2/k8s/02-tier1-frontend.yaml`:
  ```yaml
  # Comment out or delete this annotation:
  # cloud.google.com/neg: '{"ingress": true}'
  ```
  ```bash
  kubectl apply -f phase2/k8s/02-tier1-frontend.yaml
  ```

* **What to Check & Diagnostic Commands:**
  1. **Test Ingress IP Endpoint:**
     ```bash
     INGRESS_IP=$(kubectl get ingress gke-prod-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
     curl -s -I http://${INGRESS_IP}/
     # Expected Output: HTTP/1.1 502 Bad Gateway
     ```
  2. **Inspect GCP Backend Service Health:**
     ```bash
     gcloud compute backend-services list --format="table(name,healthChecks,backends[].group)"
     # Backend health shows UNHEALTHY or empty NEG targets
     ```
  3. **Check Service Annotations:**
     ```bash
     kubectl get svc frontend-service -o yaml | grep neg
     # Notice annotation is missing!
     ```

* **The Learn (Root Cause Analysis):**
  In GKE Dataplane V2, GCE Ingress defaults to Standalone Network Endpoint Groups (NEGs). Without `cloud.google.com/neg: '{"ingress": true}'`, the GCP Application Load Balancer cannot register Pod private IPs directly into its Anycast routing mesh.

* **How to Fix:**
  Restore the NEG annotation in `phase2/k8s/02-tier1-frontend.yaml`:
  ```yaml
  metadata:
    annotations:
      cloud.google.com/neg: '{"ingress": true}'
  ```
  ```bash
  kubectl apply -f phase2/k8s/02-tier1-frontend.yaml
  ```

* **Verification (How to Confirm Success):**
  ```bash
  curl -s -I http://${INGRESS_IP}/
  # Expected: HTTP/1.1 200 OK
  ```

---

### Case 7: Cloud SQL Auth Proxy IAM Role Missing (`roles/cloudsql.client`)
> [!WARNING]
> **Interview Context:** "Workload Identity is configured, but the Cloud SQL Auth Proxy sidecar logs `accessNotConfigured` or `Client does not have permission` when attempting to connect to PostgreSQL."

* **How to Break:**
  Revoke the `roles/cloudsql.client` role from the backend Service Account:
  ```bash
  gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"

  kubectl rollout restart deployment backend-deployment
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Cloud SQL Proxy Sidecar Logs:**
     ```bash
     BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
     kubectl logs $BACKEND_POD -c cloud-sql-proxy --tail=50
     ```
     *Expected Error Signature:*
     ```text
     errors: googleapi: Error 403: The client is not authorized to make this request., accessNotConfigured
     failed to get instance: Refresh error: failed to get instance metadata: 403 Forbidden
     ```
  2. **Verify Project-Level IAM Roles for the GSA:**
     ```bash
     gcloud projects get-iam-policy ${PROJECT_ID} \
       --flatten="bindings[].members" \
       --filter="bindings.members:sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com" \
       --format="table(bindings.role)"
     # Notice roles/cloudsql.client is absent!
     ```

* **The Learn (Root Cause Analysis):**
  Workload Identity validates identity (authenticating *who* the pod is), but GCP Cloud IAM controls authorization (*what* the identity can do). Without `roles/cloudsql.client`, Cloud SQL Admin API rejects the proxy's ephemeral certificate signing requests.

* **How to Fix:**
  Re-grant `roles/cloudsql.client` to the service account:
  ```bash
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:sa-app-backend@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"

  kubectl rollout restart deployment backend-deployment
  ```

* **Verification (How to Confirm Success):**
  ```bash
  BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
  kubectl logs $BACKEND_POD -c cloud-sql-proxy --tail=20
  # Expected: "The proxy has started successfully and is ready for new connections!"
  ```

---

### Case 8: Multi-AZ PVC Volume Zone Mismatch during Pod Rescheduling
> [!WARNING]
> **Interview Context:** "During a node upgrade, a pod bound to a PersistentVolume gets stuck in state `Pending` with warning `VolumeZoneConflict`."

* **How to Break:**
  Provision a zonal Persistent Disk in zone `us-east4-a` and attempt to force-schedule the consuming pod onto a node in zone `us-east4-b` via `nodeSelector`.

* **What to Check & Diagnostic Commands:**
  1. **Check Pod Status:**
     ```bash
     kubectl get pods -l tier=stateful
     # Expected: STATUS: Pending
     ```
  2. **Inspect Scheduling Failure Events:**
     ```bash
     kubectl describe pod <pending-pod>
     ```
     *Expected Error:*
     ```text
     Warning  FailedScheduling  30s  default-scheduler  0/4 nodes are available: 4 node(s) had volume node affinity conflict.
     ```

* **The Learn (Root Cause Analysis):**
  Standard GCP Compute Engine zonal Persistent Disks (`pd-standard` / `pd-balanced`) are physically bound to hypervisors in a single Availability Zone. A pod scheduled in zone `us-east4-b` cannot attach a block disk located in `us-east4-a`.

* **How to Fix:**
  Use topology-aware dynamic volume binding (`volumeBindingMode: WaitForFirstConsumer`) in the `StorageClass`:
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: topology-aware-sc
  provisioner: pd.csi.storage.gke.io
  volumeBindingMode: WaitForFirstConsumer
  allowVolumeExpansion: true
  parameters:
    type: pd-balanced
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl get pvc,pv
  # Expected: STATUS: Bound, and Pod transitions to Running in the exact AZ where the PV was provisioned
  ```

---

### Case 9: Direct Tier 1 -> Tier 3 Network Policy Violation Attempt
> [!WARNING]
> **Interview Context:** "An attacker compromises a Tier 1 frontend pod and attempts to directly scan or connect to the Cloud SQL database IP (`10.230.160.x:5432`) to bypass the API layer."

* **How to Break (Execute Attack Simulation):**
  ```bash
  CLOUDSQL_IP=$(cd phase2/terraform && terraform output -raw cloudsql_private_ip)
  FRONTEND_POD=$(kubectl get pods -l app=frontend -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it $FRONTEND_POD -- nc -zv -w 3 $CLOUDSQL_IP 5432
  ```

* **What to Check & Diagnostic Commands:**
  *Observed Attack Simulation Output:*
  ```text
  nc: connect to 10.230.160.3 port 5432 (tcp) timed out: Operation now in progress
  ```
  *Verify Active Defense Rules:*
  ```bash
  kubectl get netpol allow-tier1-frontend -o yaml
  # Confirm egress ONLY permits destination app: backend on port 8080
  ```

* **The Learn (Root Cause Analysis):**
  Under GKE Dataplane V2 (Cilium eBPF), packets originating from frontend pods destined for `10.230.160.3:5432` are dropped immediately at the Linux kernel socket level before traversing the node's physical NIC. The database layer remains completely immune to frontend compromise.

* **How to Fix:**
  No fix needed — this demonstrates verified **Zero-Trust Network Segmentation** in action!

---

### Case 10: Cloud SQL Proxy Missing `--private-ip` Flag on Private-Only Instances
> [!WARNING]
> **Interview Context:** "Your backend pod is `2/2 Running`, but executing database queries returns `Connection terminated unexpectedly` or hangs for 5 seconds."

* **How to Break:**
  Remove `--private-ip` from `cloud-sql-proxy` args in `phase2/k8s/03-tier2-backend.yaml`:
  ```yaml
  # In 03-tier2-backend.yaml
  containers:
    - name: cloud-sql-proxy
      args:
        - "--structured-logs"
        - "--port=5432"
        # Omitted: - "--private-ip"
        - "practice-502506:us-east4:cloudsql-3tier-db"
  ```
  ```bash
  kubectl apply -f phase2/k8s/03-tier2-backend.yaml
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Pod Status (Pod appears Running!):**
     ```bash
     kubectl get pods -l app=backend
     # STATUS: Running | READY: 2/2
     ```
  2. **Execute Database Health Query from API Container:**
     ```bash
     BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
     kubectl exec -it $BACKEND_POD -c api-app -- node -e 'http = require("http"); http.get("http://127.0.0.1:8080/db-health", res => res.on("data", d => console.log(d.toString())))'
     # Expected Error: {"status":"DISCONNECTED","error":"Connection terminated unexpectedly"}
     ```
  3. **Inspect Cloud SQL Proxy Logs:**
     ```bash
     kubectl logs $BACKEND_POD -c cloud-sql-proxy --tail=50
     ```
     *Expected Error Signature:*
     ```text
     [practice-502506:us-east4:cloudsql-3tier-db] failed to connect to instance: failed to get instance: instance does not have a public IP address
     ```

* **The Learn (Root Cause Analysis):**
  Cloud SQL Auth Proxy v2 defaults to looking up the target instance's Public IPv4 address. When Cloud SQL is provisioned with `ipv4_enabled = false` and connected via Private Service Access (`psa-cloudsql-ip-range`), the proxy must be explicitly instructed to route over the private network via `--private-ip`.

* **How to Fix:**
  Add `--private-ip` to the container arguments in `phase2/k8s/03-tier2-backend.yaml`:
  ```yaml
  args:
    - "--structured-logs"
    - "--port=5432"
    - "--private-ip"
    - "practice-502506:us-east4:cloudsql-3tier-db"
  ```
  ```bash
  kubectl apply -f phase2/k8s/03-tier2-backend.yaml
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl exec -it $BACKEND_POD -c api-app -- node -e 'http = require("http"); http.get("http://127.0.0.1:8080/db-health", res => res.on("data", d => console.log(d.toString())))'
  # Expected Response: {"status":"CONNECTED","database":"appdb","timestamp":"2026-08-20T..."}
  ```

---

### Case 11: Silent Node-Local-DNS Socket Drop via Restrictive NetworkPolicy
> [!WARNING]
> **Interview Context:** "After applying `default-deny-all` and an egress rule matching `k8s-app: kube-dns`, pods fail with `lookup sqladmin.googleapis.com on 10.101.0.10:53: read udp ... i/o timeout`."

* **How to Break:**
  Define the DNS egress rule using a restrictive pod label selector:
  ```yaml
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
  ```
  ```bash
  kubectl apply -f phase2/k8s/01-network-policies.yaml
  ```

* **What to Check & Diagnostic Commands:**
  1. **Check Backend API or Cloud SQL Proxy Logs:**
     ```bash
     BACKEND_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
     kubectl logs $BACKEND_POD -c cloud-sql-proxy --tail=50
     ```
     *Expected Error Signature:*
     ```text
     dial tcp: lookup sqladmin.googleapis.com on 10.101.0.10:53: read udp 10.100.1.12:52432->10.101.0.10:53: i/o timeout
     ```
  2. **Inspect Cluster DNS DaemonSets:**
     ```bash
     kubectl get pods -n kube-system -o wide --show-labels | grep dns
     # Notice GKE runs node-local-dns (label: k8s-app=node-local-dns), NOT kube-dns on node 10.101.0.10!
     ```

* **The Learn (Root Cause Analysis):**
  In GKE Dataplane V2 clusters, local DNS resolution runs as a host DaemonSet (`node-local-dns`) listening on `10.101.0.10`. Because `node-local-dns` pods carry the label `k8s-app: node-local-dns`, restricting the NetworkPolicy egress to `k8s-app: kube-dns` causes the Linux kernel eBPF filter to drop all UDP port 53 packets.

* **How to Fix:**
  In `phase2/k8s/01-network-policies.yaml`, permit UDP & TCP port 53 to all destinations:
  ```yaml
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
  ```
  ```bash
  kubectl apply -f phase2/k8s/01-network-policies.yaml
  ```

* **Verification (How to Confirm Success):**
  ```bash
  kubectl exec -it $BACKEND_POD -c api-app -- node -e 'http = require("http"); http.get("http://127.0.0.1:8080/db-health", res => res.on("data", d => console.log(d.toString())))'
  # Expected Response: {"status":"CONNECTED","database":"appdb"}
  ```


