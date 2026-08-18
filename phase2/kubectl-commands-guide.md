# Kubernetes & GKE Deep-Dive Master Guide: Core System Pods, Daemons & `kubectl` Reference

> **Context**: Complete, production-grade technical reference documenting the **Kubernetes Control Plane, Core System Pods, GKE Managed Daemons, Storage/Stateful Subsystems, Custom Resource Definitions (CRDs), `kubectl` commands, and Real-World Production Triage**.

---

# Table of Contents
1. [Kubernetes Core Architecture & API Execution Lifecycle](#1-kubernetes-core-architecture--api-execution-lifecycle)
2. [Anatomy of Default GKE System Pods & Daemons (`kube-system`, `gmp-system`, `gke-managed-*`)](#2-anatomy-of-default-gke-system-pods--daemons)
   - [2.1 DNS Resolution Subsystem (`kube-dns`, `kube-dns-autoscaler`, `node-local-dns`)](#21-dns-resolution-subsystem)
   - [2.2 Observability & Telemetry (`fluentbit-gke`, `gke-metrics-agent`, `metrics-server`, `gmp-system`)](#22-observability--telemetry)
   - [2.3 Control Plane Tunneling & Connectivity (`konnectivity-agent`, `konnectivity-agent-autoscaler`)](#23-control-plane-tunneling--connectivity)
   - [2.4 Storage & Volume Subsystem (`pdcsi-node`, `StorageClass`, `PVC`, `PV`, `VolumePopulator`)](#24-storage--volume-subsystem)
   - [2.5 Security, IAM & Workload Identity Engine (`gke-metadata-server`)](#25-security-iam--workload-identity-engine)
   - [2.6 Networking & Ingress Controllers (`netd`, `l7-default-backend`, `gke-managed-networking-dra-driver`)](#26-networking--ingress-controllers)
   - [2.7 Stateful & Batch Controllers (`StatefulSet`, `DaemonSet`, `Job`, `CronJob`)](#27-stateful--batch-controllers)
   - [2.8 GKE Core Custom Resource Definitions (CRDs) (`BackendConfig`, `FrontendConfig`, `ManagedCertificate`, `Cilium`)](#28-gke-core-custom-resource-definitions-crds)
3. [Exhaustive `kubectl` Command & Diagnostic Reference](#3-exhaustive-kubectl-command--diagnostic-reference)
   - [3.1 Cluster & Context Management](#31-cluster--context-management)
   - [3.2 Node Lifecycle & Health Inspection](#32-node-lifecycle--health-inspection)
   - [3.3 Workloads, Deployments & Pod Operations](#33-workloads-deployments--pod-operations)
   - [3.4 Storage & Persistent Volume Management](#34-storage--persistent-volume-management)
   - [3.5 Deep-Dive Debugging & Observability (Logs, Exec, Top, Port-Forward)](#35-deep-dive-debugging--observability)
   - [3.6 Networking, Services, Endpoints & Ingress](#36-networking-services-endpoints--ingress)
   - [3.7 Security, RBAC & Workload Identity Inspection](#37-security-rbac--workload-identity-inspection)
   - [3.8 eBPF Dataplane V2 & NetworkPolicies](#38-ebpf-dataplane-v2--networkpolicies)
   - [3.9 Auto-Scaling (HPA) & Resource Governance](#39-auto-scaling-hpa--resource-governance)
   - [3.10 Advanced JSONPath & Custom Columns](#310-advanced-jsonpath--custom-columns)
4. [Master Production Triage Matrix](#4-master-production-triage-matrix)
5. [Multi-Cloud Companion: AWS EKS Core System Pods, Daemons & Equivalents](#5-multi-cloud-companion-aws-eks-core-system-pods-daemons--equivalents)
6. [Hands-On "Get Dirty" Command Mastery & Production Playground](#6-hands-on-get-dirty-command-mastery--production-playground)
   - [Level 1: Cluster Identity & Context Switching](#level-1-cluster-identity--context-switching)
   - [Level 2: Worker Node Topology & Resource Reservation](#level-2-worker-node-topology--resource-reservation)
   - [Level 3: Multi-Container Pod Introspection](#level-3-multi-container-pod-introspection)
   - [Level 4: Live Container Shells, Local Socket Probes & Port-Forwarding](#level-4-live-container-shells-local-socket-probes--port-forwarding)
   - [Level 5: Real-Time Log Streaming, Crash Dumps & Cluster Event Auditing](#level-5-real-time-log-streaming-crash-dumps--cluster-event-auditing)
   - [Level 6: Advanced JSONPath Expressions & Custom Terminal Dashboards](#level-6-advanced-jsonpath-expressions--custom-terminal-dashboards)
   - [Level 7: Production Chaos, Zero-Downtime Rollouts & HPA Load Testing](#level-7-production-chaos-zero-downtime-rollouts--hpa-load-testing)

---

# 1. Kubernetes Core Architecture & API Execution Lifecycle

When any interaction occurs via `kubectl` or an internal controller, the request executes through a strictly sequenced distributed control loop:

```
 [ Engineer / Terminal: kubectl ]
                │
                ▼ (Reads ~/.kube/config & gke-gcloud-auth-plugin)
 [ kube-apiserver ] (Master Control Plane - Stateless REST API)
    ├── 1. Authentication (mTLS, OIDC Token, GCP IAM OAuth2 via Google STS)
    ├── 2. Authorization (RBAC - ClusterRole, RoleBinding)
    ├── 3. Mutating Admission Webhooks (Injects sidecars e.g. Cloud SQL Proxy)
    ├── 4. Schema Validation (Validates YAML/JSON against OpenAPI specs)
    └── 5. Validating Admission Webhooks (Resource limits, Security policies)
                │
                ▼ (Atomic Commit to Raft Distributed Log)
 [ etcd Key-Value Store ] (Cluster State Database)
                │
                ├─────────────────────────────┬─────────────────────────────┐
                ▼                             ▼                             ▼
        [ kube-scheduler ]        [ kube-controller-manager ]     [ Cloud Controller ]
        (Places Pods on Nodes)     (HPA, ReplicaSet, Endpoints)   (GCP Load Balancers, NEGs)
```

---

# 2. Anatomy of Default GKE System Pods & Daemons

When you provision a Google Kubernetes Engine (GKE) cluster, GCP deploys essential infrastructure daemons inside the `kube-system`, `gmp-system`, and `gke-managed-*` namespaces. Every pod has a dedicated architectural purpose:

---

### 2.1 DNS Resolution Subsystem

#### **1. `kube-dns` (Deployment / Pods)**
- **Namespace**: `kube-system`
- **What it is**: Core internal DNS server (based on SkyDNS/CoreDNS) handling service discovery for all pods in the cluster.
- **Why it exists**: Translates friendly Kubernetes service names (e.g. `backend-service.default.svc.cluster.local`) into virtual ClusterIP addresses (`10.101.x.x`).
- **If it fails**: Pods fail to connect to other microservices and log `getaddrinfo ENOTFOUND` or `Could not resolve host`.

#### **2. `kube-dns-autoscaler` (Deployment)**
- **Namespace**: `kube-system`
- **What it is**: Proportional autoscaler controller that monitors total cluster CPU cores and node count.
- **Why it exists**: Dynamically scales the replica count of `kube-dns` as the cluster grows, preventing DNS query bottlenecks when thousands of pods make concurrent queries.

#### **3. `node-local-dns` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it is**: Runs a localized DNS caching agent on **every single worker node** listening on local IP `169.254.20.10`.
- **Why it exists**:
  - **Latency Optimization**: Pods resolve DNS queries locally on the same VM hypervisor without sending UDP packets across the physical network to `kube-dns`.
  - **Connection Tracking**: Avoids Linux kernel conntrack table exhaustion caused by high UDP DNS packet rates.
  - **TCP Fallback**: Upgrades UDP DNS queries to TCP when forwarding to upstream DNS to eliminate packet drop timeouts.

---

### 2.2 Observability & Telemetry

#### **4. `fluentbit-gke` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it is**: High-performance, lightweight log forwarder running on every node.
- **Why it exists**: Tails `/var/log/containers/*.log` from the node host filesystem, enriches logs with Kubernetes metadata (Pod Name, Namespace, Container Name, Labels), and streams them directly into **Google Cloud Logging (Cloud Operations / Stackdriver)**.

#### **5. `gke-metrics-agent` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it is**: Node-level metrics collector agent.
- **Why it exists**: Scrapes system and container hardware metrics (CPU, RAM, Network I/O, Disk usage) from the Kubelet `/metrics` endpoint and exports them to **Google Cloud Monitoring**.

#### **6. `metrics-server` (Deployment)**
- **Namespace**: `kube-system`
- **What it is**: In-memory aggregator of resource usage data scraped from Kubelet.
- **Why it exists**: Serves the `metrics.k8s.io` API. **Required by `kubectl top nodes`, `kubectl top pods`, and the Horizontal Pod Autoscaler (HPA)** to compute real-time CPU% against target thresholds.

#### **7. `gmp-system` Pods (Google Managed Prometheus)**
- **Namespace**: `gmp-system` & `gmp-public`
- **What it is**: Managed Prometheus collector and rule evaluator.
- **Why it exists**: Scrapes custom application Prometheus metrics endpoints (e.g. `/metrics`) without requiring you to manage self-hosted Prometheus servers, TSDB storage disks, or Grafana infrastructure.

---

### 2.3 Control Plane Tunneling & Connectivity

#### **8. `konnectivity-agent` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it is**: Secure network proxy agent running inside the customer VPC.
- **Why it exists**: In Private GKE Clusters, the Kubernetes Control Plane Master VM resides in a Google-managed Tenant VPC. The Master cannot initiate inbound connections to private worker nodes. `konnectivity-agent` establishes a secure outbound TLS tunnel from the worker nodes to the master.
- **What breaks if it dies**: `kubectl logs`, `kubectl exec`, and `kubectl port-forward` will fail with `dial tcp: i/o timeout` or `error dialing backend`.

#### **9. `konnectivity-agent-autoscaler` (Deployment)**
- **Namespace**: `kube-system`
- **What it is**: Automatically scales `konnectivity-agent` replicas based on cluster size to handle high concurrency of `exec` and `logs` streaming tunnels.

---

### 2.4 Storage & Volume Subsystem

#### **10. `pdcsi-node` (DaemonSet - Persistent Disk CSI Driver)**
- **Namespace**: `kube-system`
- **What it is**: Container Storage Interface (CSI) node plugin.
- **Why it exists**: Communicates directly with the Linux kernel on the VM host to attach, format (ext4/xfs), and mount Google Cloud Persistent Disks (`pd-standard`, `pd-ssd`) into Pod container volumes (`/var/lib/kubelet/pods/.../volumes`).

#### **11. `gke-managed-volumepopulator`**
- **Namespace**: `gke-managed-volumepopulator`
- **What it is**: Controller responsible for populating persistent volume claims from external storage sources, snapshots, or disk clones.

#### **12. Storage Abstractions: `StorageClass`, `PV`, and `PVC`**
- **`StorageClass` (`sc`)**: Defines the provisioner (e.g. `pd.csi.storage.gke.io`), disk type (`pd-balanced`, `pd-ssd`), replication, and reclaim policies.
- **`PersistentVolumeClaim` (`pvc`)**: A request for storage by a user/pod (e.g. "I need 50Gi of ReadWriteOnce storage").
- **`PersistentVolume` (`pv`)**: The actual cloud disk provisioned in GCP and bound to the PVC.

---

### 2.5 Security, IAM & Workload Identity Engine

#### **13. `gke-metadata-server` (DaemonSet - Workload Identity Engine)**
- **Namespace**: `kube-system`
- **What it is**: The core engine of **GKE Workload Identity**.
- **Why it exists**: Intercepts all pod network requests to the Google Cloud Instance Metadata IP (`http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token`).
- **How it works**:
  1. Pod with `serviceAccountName: ksa-app-backend` requests a GCP token.
  2. `gke-metadata-server` intercepts the call, validates the KSA JWT token against the GKE OpenID Connect (OIDC) provider.
  3. Impersonates the bound GCP IAM Service Account (`sa-app-backend@PROJECT_ID.iam.gserviceaccount.com`).
  4. Returns a temporary short-lived OAuth2 access token to the pod.
  5. **Prevents storing dangerous static GCP Service Account JSON keys inside containers.**

---

### 2.6 Networking & Ingress Controllers

#### **14. `netd` (DaemonSet - Network Controller)**
- **Namespace**: `kube-system`
- **What it is**: GKE SDN network daemon.
- **Why it exists**: Configures IP address management (IPAM), Linux routing tables, IP masquerading (IP-Masq agent), and VPC-native secondary IP alias allocations for pods.

#### **15. `l7-default-backend` (Deployment)**
- **Namespace**: `kube-system`
- **What it is**: Default fallback HTTP web server.
- **Why it exists**: When an Ingress Load Balancer receives a request matching no configured URL paths or rules, it routes the traffic to `l7-default-backend`, which returns a clean `default backend - 404`.

#### **16. `gke-managed-networking-dra-driver`**
- **Namespace**: `gke-managed-networking-dra-driver`
- **What it is**: Dynamic Resource Allocation (DRA) driver for specialized hardware networking (e.g. multi-network interfaces, GPU direct RDMA).

---

### 2.7 Stateful & Batch Controllers

#### **17. `StatefulSet` (`sts`)**
- **What it is**: Controller designed for stateful workloads requiring stable network IDs and persistent storage across pod restarts (e.g. Kafka, ZooKeeper, Elasticsearch, Cassandra).
- **Key Characteristics**:
  - Deterministic Pod naming: `pod-0`, `pod-1`, `pod-2`.
  - Ordered, graceful deployment and scaling ($0 \rightarrow 1 \rightarrow 2$).
  - `volumeClaimTemplates`: Automatically creates dedicated PVCs per replica that persist even if pods are deleted.

#### **18. `DaemonSet` (`ds`)**
- **What it is**: Ensures that all (or some) nodes run exactly one copy of a Pod.
- **Why it exists**: Ideal for node-level system agents (e.g. `fluentbit-gke`, `node-local-dns`, `gke-metadata-server`).

#### **19. `Job` & `CronJob` (`job`, `cj`)**
- **`Job`**: Runs batch processes to completion (e.g. database migrations, schema seeding) and terminates with `Exit Code 0`.
- **`CronJob`**: Schedules `Jobs` to run periodically on a cron schedule (e.g. nightly backups, cache clearing).

---

### 2.8 GKE Core Custom Resource Definitions (CRDs)

In GKE, Google extends the Kubernetes API with Custom Resources:
1. **`BackendConfig` (`cloud.google.com/v1`)**: Configures Layer 7 Load Balancer settings (Cloud Armor WAF security policies, connection draining timeouts, CDN caching, custom HTTP health checks).
2. **`FrontendConfig` (`networking.gke.io/v1beta1`)**: Configures HTTP-to-HTTPS redirect rules and TLS security policies on the Load Balancer frontend.
3. **`ManagedCertificate` (`networking.gke.io/v1`)**: Provisions and automatically renews Google-managed SSL/TLS certificates for custom domain names.
4. **`CiliumNetworkPolicy` / `CiliumEndpoint` (`cilium.io`)**: GKE Dataplane V2 internal CRDs tracking eBPF BPF maps and Layer 7 network security rules.

---

# 3. Exhaustive `kubectl` Command & Diagnostic Reference

---

### 3.1 Cluster & Context Management

#### **`kubectl config view`**
- **Under the Hood**: Reads `$HOME/.kube/config`, decrypts sensitive tokens, merges multi-file `$KUBECONFIG` paths, and presents the YAML representation.
- **Flags**:
  - `--minify`: Strips inactive contexts, displaying only the active cluster endpoint and credentials.
  - `--raw`: Displays unmasked base64 client certificates and Bearer tokens.
```bash
# View active cluster config without redaction
kubectl config view --minify --raw
```

#### **`kubectl config get-contexts` / `use-context`**
- **Under the Hood**: Lists or mutates the `current-context` field inside `kubeconfig`.
```bash
# List all contexts
kubectl config get-contexts

# Switch context to GKE cluster
kubectl config use-context gke_practice-502506_us-east4-a_gke-3tier-prod
```

#### **`kubectl cluster-info`**
- **Under the Hood**: Queries `GET /api` and `GET /apis` on the master API server and returns active control plane service URLs.
```bash
kubectl cluster-info
```

---

### 3.2 Node Lifecycle & Health Inspection

#### **`kubectl get nodes -o wide`**
- **Under the Hood**: Queries `GET /api/v1/nodes`.
- **Output Columns Explained**:
  - `STATUS`: `Ready` (Kubelet posting healthy node status).
  - `ROLES`: `<none>` (GKE manages control plane separately; workers have no manual role label).
  - `INTERNAL-IP`: Private VPC IP address (`10.0.2.x`).
  - `OS-IMAGE`: Google Container-Optimized OS (COS).
  - `CONTAINER-RUNTIME`: `containerd://2.x` (Direct OCI runtime).
```bash
kubectl get nodes -o wide
```

#### **`kubectl describe node <NODE_NAME>`**
- **Under the Hood**: Retrieves the `Node` object and parses `Conditions`, `Allocatable` resources, `Taints`, and running `Pod` resource request reservations.
- **What to Look For**:
  - `Allocatable`: Free CPU/Memory left for pods after GKE system overhead.
  - `Conditions`: All should be `False` except `Ready=True`.
```bash
kubectl describe node gke-gke-3tier-prod-np-app-tier-4a5c7f21-ckr8
```

#### **`kubectl top nodes`**
- **Under the Hood**: Queries `GET /apis/metrics.k8s.io/v1beta1/nodes` to aggregate real-time hardware consumption.
```bash
kubectl top nodes --sort-by=cpu
```

#### **`kubectl cordon` / `uncordon` / `drain`**
```bash
# Prevent new pods from scheduling onto node
kubectl cordon <NODE_NAME>

# Evict all pods safely for node maintenance
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data --force

# Re-enable scheduling
kubectl uncordon <NODE_NAME>
```

---

### 3.3 Workloads, Deployments & Pod Operations

#### **`kubectl get pods`**
- **Flags**:
  - `-A`: Lists pods across all system and application namespaces.
  - `-o wide`: Displays Pod IP addresses (`10.100.x.x`) and the VM node hosting each pod.
  - `-w`: Streams real-time pod status transitions (`ContainerCreating` $\rightarrow$ `Running`).
```bash
kubectl get pods -A -o wide
```

#### **`kubectl describe pod <POD_NAME>`**
- **Under the Hood**: Queries `GET /api/v1/namespaces/<NS>/pods/<NAME>` and extracts container exit codes, mount statuses, and chronological Kubelet events.
- **Critical Diagnostics**:
  - `Exit Code 0`: Success / Normal completion.
  - `Exit Code 1`: Application runtime crash / Uncaught JS Exception.
  - `Exit Code 137`: **OOMKilled** (Linux kernel Out-Of-Memory killer terminated container).
  - `Exit Code 139`: Segmentation fault.
```bash
kubectl describe pod backend-deployment-78685646f4-qx7zs
```

#### **`kubectl rollout status` / `history` / `undo`**
```bash
# Track rolling deployment in real time (blocks until 100% healthy)
kubectl rollout status deployment/backend-deployment --timeout=90s

# View deployment revisions
kubectl rollout history deployment/backend-deployment

# Rollback to previous deployment revision
kubectl rollout undo deployment/backend-deployment
```

---

### 3.4 Storage & Persistent Volume Management

#### **`kubectl get sc` / `get pvc` / `get pv`**
- **What it does**: Inspects storage classes, volume claims, and bound persistent disks.
```bash
# List available StorageClasses in GKE
kubectl get sc

# Check status of persistent volume claims
kubectl get pvc -A

# Check bound persistent volumes and capacity
kubectl get pv
```

---

### 3.5 Deep-Dive Debugging & Observability (Logs, Events, Exec, Top, Port-Forward)

---

#### **A. The Complete `kubectl logs` Master Reference**

- **Under the Hood**: Kubelet acts as the streaming proxy. When you run `kubectl logs`, the API server connects to the node's Kubelet on port 10250. Kubelet reads directly from the container runtime log file located on the node filesystem at `/var/log/pods/<NAMESPACE>_<POD_NAME>_<POD_UID>/<CONTAINER_NAME>/<RESTART_COUNT>.log` (which is symlinked to `containerd`'s `/var/log/containers/`).
- **All Flags & Parameters Explained**:
  - `-c <CONTAINER_NAME>`: Specifies the exact container in a multi-container pod (e.g. `api-app` vs `cloud-sql-proxy`).
  - `--all-containers=true`: Concurrently streams logs from every container inside the pod with container names prepended.
  - `-l <LABEL_SELECTOR>`: Aggregates logs across multiple pods matching labels (e.g. `-l app=backend`).
  - `-f` or `--follow`: Keeps the connection open, continuously streaming live log output as new lines are written.
  - `--tail=<N>`: Displays only the most recent N lines (default: all lines, which can flood terminals in high-traffic apps).
  - `-p` or `--previous`: **The #1 Crash Debugger.** Pulls logs from the *previously terminated container instance* before it crashed and rebooted.
  - `--since=<DURATION>`: Filters logs generated within a specific timeframe (e.g. `--since=15m`, `--since=1h`, `--since=30s`).
  - `--since-time=<TIMESTAMP>`: Filters logs generated after an exact RFC3339 timestamp (e.g. `--since-time=2026-08-14T10:00:00Z`).
  - `--timestamps=true`: Prepends exact RFC3339 timestamps to each log line for precise correlation with database/firewall logs.
  - `--limit-bytes=<N>`: Enforces a maximum byte threshold to prevent terminal buffer overflow.
  - `--max-log-requests=<N>`: Sets the maximum number of concurrent logs streams when querying by label (default: 5).

---

#### **B. The Complete `kubectl get events` Master Reference**

- **Under the Hood**: Kubernetes `Event` objects (`apiGroup: events.k8s.io/v1`) are transient state change records created by system controllers (`kube-scheduler`, `kubelet`, `node-controller`, `ingress-controller`, `hpa-controller`). Events are stored in `etcd` with an automatic **1-hour TTL eviction policy**.
- **All Flags & Parameters Explained**:
  - `-A` or `--all-namespaces`: Aggregates events across the entire cluster.
  - `--sort-by='.metadata.creationTimestamp'`: **Essential.** Sorts events chronologically from oldest to newest.
  - `--field-selector type=Warning`: Filters out routine `Normal` events to isolate critical cluster errors, node pressures, and probe failures.
  - `--field-selector involvedObject.kind=Pod`: Filters events for a specific resource type (`Pod`, `Node`, `Service`, `Ingress`, `HPA`).
  - `--field-selector involvedObject.name=<NAME>`: Isolates events affecting a single named resource.
  - `-w` or `--watch`: Streams live cluster events as they happen.

---

#### **C. 12 Practical Real-World Scenarios: Logs & Events Debugging**

##### **Scenario 1: Debugging `CrashLoopBackOff` (The Silent Fatal Crash)**
- **Symptom**: Pod status cycles between `Running (0/2)` and `CrashLoopBackOff`.
- **Command**:
  ```bash
  # 1. Fetch previous crash log before container rebooted
  kubectl logs -l app=backend -c api-app --previous --tail=100

  # 2. Check why Kubelet killed the container
  kubectl get events --field-selector involvedObject.name=backend-deployment-78685646f4-qx7zs --sort-by='.metadata.creationTimestamp'
  ```
- **What to look for in output**: Uncaught Node.js exceptions (`Uncaught Error: Connection refused at 127.0.0.1:5432`), missing environment variables, or schema migration failures.

---

##### **Scenario 2: Diagnosing `OOMKilled` (Exit Code 137)**
- **Symptom**: Pod restarts repeatedly. `kubectl get pods` shows `RESTARTS > 10`.
- **Command**:
  ```bash
  # 1. Check container termination reason
  kubectl describe pod -l app=backend | grep -E "State|Exit Code|Reason"

  # 2. Check OOM kill event in cluster event stream
  kubectl get events -A --field-selector type=Warning --sort-by='.metadata.creationTimestamp' | grep -i "OOM"
  ```
- **Expected Output**:
  ```text
  Last State: Terminated
    Reason: OOMKilled
    Exit Code: 137
  ```
- **Action**: Container memory exceeded `resources.limits.memory`. Increase memory limit or profile JavaScript heap usage.

---

##### **Scenario 3: Debugging Cloud SQL Proxy Sidecar TLS Handshake Failures**
- **Symptom**: Node.js backend throws `ECONNREFUSED` or hangs when executing SQL queries.
- **Command**:
  ```bash
  # Stream Cloud SQL Proxy sidecar logs with timestamps
  kubectl logs -l app=backend -c cloud-sql-proxy --timestamps=true --tail=50 -f
  ```
- **What to look for in output**:
  - `Ready for new connections`: Sidecar is healthy.
  - `googleapi: Error 403: The client is not authorized`: Workload Identity missing `roles/cloudsql.client` on IAM Service Account.
  - `instance connection name not found`: Typo in `PROJECT_ID:REGION:INSTANCE_NAME` argument.

---

##### **Scenario 4: Diagnosing `ImagePullBackOff` & `ErrImagePull`**
- **Symptom**: Pod stuck in `ImagePullBackOff` or `ErrImagePull`.
- **Command**:
  ```bash
  kubectl get events --field-selector type=Warning --sort-by='.metadata.creationTimestamp'
  ```
- **Expected Output in Events**:
  ```text
  Warning  Failed     32s   kubelet  Failed to pull image "us-east4-docker.pkg.dev/.../app-p2:latest": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: unexpected status code 403 Forbidden
  ```
- **Root Cause & Action**: Node Service Account (`sa-gke-nodes`) is missing `roles/artifactregistry.reader` permission, or the image tag does not exist.

---

##### **Scenario 5: Diagnosing Readiness Probe Failures (Service Removing Pods from Traffic)**
- **Symptom**: Pod shows `Running (1/2)` or Service endpoints drop to `<none>`, causing HTTP 502.
- **Command**:
  ```bash
  # 1. Check probe failure events
  kubectl get events --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'

  # 2. Check application server logs during probe window
  kubectl logs -l app=backend -c api-app --since=5m --tail=50
  ```
- **Expected Output in Events**:
  ```text
  Warning  Unhealthy  12s (x6 over 42s)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
  ```
- **Action**: Pod is alive but `/health` route is returning 500 (e.g. database pool connection timed out).

---

##### **Scenario 6: Diagnosing Layer 7 Ingress & BackendConfig Health Check Failures**
- **Symptom**: Public Ingress IP returns `HTTP 502 Bad Gateway`.
- **Command**:
  ```bash
  # 1. Check Ingress Controller events
  kubectl describe ingress gke-prod-ingress | grep -A 10 Events

  # 2. Check Google Load Balancer backend health annotations
  kubectl get ingress gke-prod-ingress -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}'
  ```
- **Expected Output**:
  ```text
  {"k8s1-ad76bf7b-default-frontend-service-80-a9fb50d3":"UNHEALTHY"}
  ```
- **Root Cause**: Nginx frontend is not responding with HTTP 200 on `/` to Google's Load Balancer health check probe IP ranges (`130.211.0.0/22`, `35.191.0.0/16`).

---

##### **Scenario 7: Diagnosing `FailedScheduling` (Resource Starvation)**
- **Symptom**: Pod stays in `Status: Pending`.
- **Command**:
  ```bash
  kubectl get events --field-selector reason=FailedScheduling --sort-by='.metadata.creationTimestamp'
  ```
- **Expected Output in Events**:
  ```text
  Warning  FailedScheduling  18s  default-scheduler  0/2 nodes are available: 2 Insufficient cpu, 2 Insufficient memory.
  ```
- **Action**: Cluster nodes have exhausted physical hardware. Scale up the GKE node pool or reduce `resources.requests.cpu` in Deployment YAML.

---

##### **Scenario 8: Multi-Container Parallel Log Streaming**
- **Symptom**: Need to observe real-time interaction between `api-app` and `cloud-sql-proxy` sidecar simultaneously during live HTTP requests.
- **Command**:
  ```bash
  # Stream both containers simultaneously with timestamps
  kubectl logs -l app=backend --all-containers=true --timestamps=true -f --max-log-requests=10
  ```

---

##### **Scenario 9: Correlating Application Timeouts with NetworkPolicy Dropped Packets**
- **Symptom**: Frontend pod logs `ETIMEDOUT` when calling `http://backend-service:8080`.
- **Command**:
  ```bash
  # 1. Check frontend pod logs for exact timeout timestamp
  kubectl logs -l app=frontend --timestamps=true --tail=30

  # 2. Check eBPF Dataplane V2 (Cilium) drop events in kube-system
  kubectl get events -n kube-system --field-selector type=Warning --sort-by='.metadata.creationTimestamp'
  ```
- **Action**: NetworkPolicy `allow-tier2-backend` is blocking traffic because ingress port 8080 or pod label selectors are misconfigured.

---

##### **Scenario 10: Tracking Horizontal Pod Autoscaler (HPA) Scale-Up and Scale-Down Events**
- **Symptom**: Need to audit when and why HPA triggered a replica expansion.
- **Command**:
  ```bash
  kubectl get events --field-selector involvedObject.name=backend-hpa --sort-by='.metadata.creationTimestamp'
  ```
- **Expected Output in Events**:
  ```text
  Normal  SuccessfulRescale  2m   horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target 70%
  Normal  SuccessfulRescale  30s  horizontal-pod-autoscaler  New size: 2; reason: All metrics below target thresholds (stabilization window passed)
  ```

---

##### **Scenario 11: Exporting Cluster Warning Events for Incident RCA Reports**
- **Symptom**: Generating a post-mortem incident report after an outage.
- **Command**:
  ```bash
  # Export all warning events from the last hour formatted in a clean table
  kubectl get events -A \
    --field-selector type=Warning \
    --sort-by='.metadata.creationTimestamp' \
    -o custom-columns=TIME:.metadata.creationTimestamp,NAMESPACE:.metadata.namespace,KIND:.involvedObject.kind,NAME:.involvedObject.name,REASON:.reason,MESSAGE:.message
  ```

---

##### **Scenario 12: Live Streaming All System & Application Errors Simultaneously**
- **Symptom**: Monitoring cluster health during a production release or chaos engineering test.
- **Command**:
  ```bash
  # Watch all warning events stream across all namespaces in real time
  kubectl get events -A --field-selector type=Warning -w
  ```

---

#### **D. Interactive Debugging with `kubectl exec`**
- **Under the Hood**: Instructs Kubelet to invoke `containerd` to spawn a process inside the container's PID, Mount, and Network namespaces.
```bash
# 1. Open interactive shell inside API container
kubectl exec -it deployment/backend-deployment -c api-app -- /bin/sh

# 2. Test internal database port reachability from API pod over localhost
kubectl exec -it deployment/backend-deployment -c api-app -- nc -zv 127.0.0.1 5432

# 3. Test DNS resolution inside pod
kubectl exec -it deployment/backend-deployment -c api-app -- nslookup backend-service
```

---

#### **E. Private Tunneling with `kubectl port-forward`**
- **Under the Hood**: Opens a TCP listener on localhost, multiplexing streams across the API server tunnel directly to the container's network namespace.
```bash
# 1. Forward local port 8080 to internal backend Service
kubectl port-forward svc/backend-service 8080:8080

# 2. Forward local port 5432 to Cloud SQL Proxy inside a backend pod
kubectl port-forward pod/backend-deployment-78685646f4-qx7zs 5432:5432
```

---

#### **F. Live Resource Metrics with `kubectl top`**
- **Under the Hood**: Queries `metrics.k8s.io` to aggregate real-time hardware consumption.
```bash
# 1. View live CPU & Memory usage per node
kubectl top nodes --sort-by=cpu

# 2. View live CPU & Memory usage per individual container
kubectl top pods --containers --sort-by=memory
```

---

### 3.6 Networking, Services, Endpoints & Ingress

#### **`kubectl get svc` / `describe svc`**
- **Under the Hood**: Services are virtual IP abstractions. In GKE Dataplane V2, `kube-proxy` is replaced by eBPF maps that translate `ClusterIP:Port` directly to `PodIP:Port` in the Linux kernel.
```bash
kubectl describe svc backend-service
```

#### **`kubectl get endpoints` / `endpointslices`**
- **Under the Hood**: Endpoints controller watches Pod label selectors and readiness probes. If a pod fails its readiness check, its IP is immediately removed from Endpoints.
```bash
kubectl get endpoints backend-service
```

#### **`kubectl get ingress` / `describe ingress`**
- **Under the Hood**: The GKE Ingress Controller reads the Ingress spec, provisions a Google Cloud Global External Application Load Balancer, creates Backend Services, attaches Standalone NEGs, and tracks health.
```bash
kubectl describe ingress gke-prod-ingress | grep -E "Address|backends"
```

---

### 3.7 Security, RBAC & Workload Identity Inspection

#### **`kubectl auth can-i`**
- **Under the Hood**: Sends a `SelfSubjectAccessReview` or `SubjectAccessReview` payload to the API server's RBAC engine.
```bash
# Test if Cloud Build service account can deploy workloads
kubectl auth can-i create deployments --as=985299229640-compute@developer.gserviceaccount.com
```

#### **`kubectl describe sa <NAME>`**
- **Under the Hood**: Verifies Workload Identity annotation linkage:
  `iam.gke.io/gcp-service-account: sa-app-backend@practice-502506.iam.gserviceaccount.com`.
```bash
kubectl describe sa ksa-app-backend
```

---

### 3.8 eBPF Dataplane V2 & NetworkPolicies

#### **`kubectl get networkpolicy` / `describe netpol`**
- **Under the Hood**: GKE Dataplane V2 compiles NetworkPolicy rules directly into **Cilium eBPF bytecode programs** attached to TC (Traffic Control) hooks on container `veth` interfaces.
- **Why it matters**: Zero iptables performance degradation ($O(1)$ hash map lookup).
```bash
kubectl describe networkpolicy allow-tier2-backend
```

---

### 3.9 Auto-Scaling (HPA) & Resource Governance

#### **`kubectl get hpa` / `describe hpa`**
- **Under the Hood**: HPA controller executes every 15 seconds:
  $$\text{Desired Replicas} = \lceil \text{Current Replicas} \times \frac{\text{Current CPU \%}}{\text{Target CPU \%}} \rceil$$
```bash
kubectl get hpa backend-hpa -w
```

---

### 3.10 Advanced JSONPath & Custom Columns

```bash
# 1. Extract only the Public Ingress IP
kubectl get ingress gke-prod-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# 2. Print Pod Name, Host Node IP, and Pod IP in a clean table
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.nodeName}{"\n"}{end}'

# 3. Custom columns table for memory & CPU allocations
kubectl get pods -o custom-columns=NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_LIMIT:.spec.containers[*].resources.limits.memory,STATUS:.status.phase
```

---

# 4. Master Production Triage Matrix

| Failure State | Diagnostic Execution | Root Cause & Resolution Action |
|---|---|---|
| **`CrashLoopBackOff`** | `kubectl logs <POD> -c <CONTAINER> --previous` | Application crashed at boot. Check stack trace, database connection string, or missing secrets. |
| **`Pending`** | `kubectl describe pod <POD>` | Insufficient CPU/Memory on worker nodes. Scale node pool or adjust pod resource requests. |
| **`ImagePullBackOff`** | `kubectl describe pod <POD>` | 1. Typo in image name/tag.<br>2. Missing `roles/artifactregistry.reader` on Node Service Account. |
| **`OOMKilled` (Exit 137)** | `kubectl describe pod <POD>` | Container exceeded `resources.limits.memory`. Increase memory limit in Deployment YAML. |
| **`HTTP 502 / 503` on Service** | `kubectl get endpoints <SVC>` | If `ENDPOINTS` is `<none>`, check `spec.selector` in Service YAML vs Pod labels, or check failing readiness probes. |
| **`HPA <unknown>/70%`** | `kubectl describe hpa <HPA>` | Deployment Pod template is missing `resources.requests.cpu`. HPA cannot calculate percentage without baseline request. |
| **DNS Resolution Failure** | `kubectl exec -it <POD> -- nslookup kubernetes.default` | NetworkPolicy is blocking egress UDP port 53 to `k8s-app: kube-dns`, or `kube-dns` / `node-local-dns` pods are crashed. |
| **Workload Identity `403`** | `kubectl describe sa <KSA>` | Missing `iam.gke.io/gcp-service-account` annotation on KSA, or missing `roles/iam.workloadIdentityUser` binding on GCP IAM SA. |
| **Delete Stuck Terminating Pod**| `kubectl delete pod <POD> --grace-period=0 --force` | Underlying Node VM became unresponsive/lost network connectivity while holding pod lock. |

---

# 5. Multi-Cloud Companion: AWS EKS Core System Pods, Daemons & Equivalents

When managing Kubernetes on **Amazon Web Services (AWS EKS)**, the architecture mirrors GKE with AWS-native controllers and daemonsets:

---

### 5.1 AWS EKS System Pods & Daemons Breakdown

```
┌──────────────────────────────────────┬──────────────────────────────────────┬────────────────────────────────────────────────────────┐
│ Function / Layer                     │ GKE System Pod (GCP)                 │ AWS EKS System Pod (AWS)                               │
├──────────────────────────────────────┼──────────────────────────────────────┼────────────────────────────────────────────────────────┤
│ **Container Networking (CNI)**       │ `netd` / Dataplane V2 (Cilium eBPF)   │ `aws-node` (AWS VPC CNI DaemonSet)                     │
│ **Internal DNS**                     │ `kube-dns` + `node-local-dns`        │ `coredns` + NodeLocal DNSCache                         │
│ **Cluster Proxy**                    │ Managed eBPF kernel maps             │ `kube-proxy` (iptables/IPVS daemonset)                 │
│ **Storage Controller**               │ `pdcsi-node` (Compute Engine PD)     │ `aws-ebs-csi-driver-node` / `ebs-csi-controller`       │
│ **IAM & Identity Engine**            │ `gke-metadata-server`                │ `eks-pod-identity-agent` / AWS STS OIDC Webhook        │
│ **Ingress / ALB Controller**         │ `loadbalancer-controller` (GCE)      │ `aws-load-balancer-controller`                         │
│ **Logging & Monitoring**             │ `fluentbit-gke` + `gke-metrics-agent`│ `aws-for-fluent-bit` + `amazon-cloudwatch-agent`       │
│ **Node Autoscaling**                 │ GKE Cluster Autoscaler               │ **Karpenter** / `cluster-autoscaler`                   │
└──────────────────────────────────────┴──────────────────────────────────────┴────────────────────────────────────────────────────────┘
```

#### **1. `aws-node` (AWS VPC CNI DaemonSet)**
- **Namespace**: `kube-system`
- **What it does**: Allocates native AWS VPC Secondary Private IP addresses directly to Pods from the node's Elastic Network Interfaces (ENIs).
- **Why it matters**: Allows Pods to communicate directly with Amazon RDS, ElastiCache, and other VPC services without NAT or overlay routing.

#### **2. `coredns` (Deployment)**
- **Namespace**: `kube-system`
- **What it does**: Default DNS service discovery for Amazon EKS clusters.

#### **3. `aws-ebs-csi-driver-node` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it does**: CSI driver that communicates with AWS EC2 API to provision, attach, format, and mount Amazon Elastic Block Store (EBS `gp3`/`io2`) volumes into Pods.

#### **4. `eks-pod-identity-agent` (DaemonSet)**
- **Namespace**: `kube-system`
- **What it does**: The AWS equivalent of `gke-metadata-server`. Intercepts metadata calls and provides temporary AWS IAM credentials to pods using EKS Pod Identity associations.

#### **5. `aws-load-balancer-controller` (Deployment)**
- **Namespace**: `kube-system`
- **What it does**: Manages AWS Application Load Balancers (ALB) and Network Load Balancers (NLB). Automatically provisions target groups and configures IP mode routing (`alb.ingress.kubernetes.io/target-type: ip`).

---

### 5.2 Essential AWS CLI + `kubectl` Workflow Commands

```bash
# 1. Update kubeconfig to connect to an Amazon EKS Cluster
aws eks update-kubeconfig --region us-east-1 --name eks-3tier-prod

# 2. Check AWS CNI health on all nodes
kubectl get daemonset aws-node -n kube-system

# 3. Check AWS Load Balancer Controller logs for Ingress provisioning errors
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=50 -f

# 4. Check AWS EBS CSI Driver logs for persistent volume mount failures
kubectl logs -n kube-system -l app=ebs-csi-node -c ebs-plugin --tail=50

# 5. Verify IRSA / IAM Role annotation on Kubernetes Service Account in AWS
kubectl describe sa ksa-app-backend | grep -i "eks.amazonaws.com/role-arn"
```

---

# 6. Hands-On "Get Dirty" Command Mastery & Production Playground

This section provides an actionable, interactive command reference arranged progressively from core cluster introspection to live chaos engineering. **Every single command, flag, parameter, and output value is explained in depth.**

---

### Level 1: Cluster Identity & Context Switching

#### **1. `kubectl config current-context`**
- **Syntax**: `kubectl config current-context`
- **Explanation**: Reads `~/.kube/config` and prints the active cluster context name (e.g. `gke_practice-502506_us-east4-a_gke-3tier-prod`).
- **Why use it**: Run this before any write operation (`apply`, `delete`) to ensure you are targeting the intended cluster.

#### **2. `kubectl config get-contexts`**
- **Syntax**: `kubectl config get-contexts`
- **Explanation**: Lists all registered clusters, user authentication tokens, and namespaces, highlighting the active cluster with `*`.

#### **3. `kubectl config view --minify --raw`**
- **Syntax**: `kubectl config view --minify --raw`
- **Explanation**: `--minify` filters the output to only the active cluster. `--raw` prevents redaction of base64 client certificates (`client-certificate-data`) and Bearer tokens.
- **Why use it**: Extract raw cluster CA certificates and API server hostnames when writing automation scripts or configuring external CI/CD pipelines.

#### **4. `kubectl cluster-info`**
- **Syntax**: `kubectl cluster-info`
- **Explanation**: Queries `GET /api` on the control plane and returns the live URLs of the Kubernetes Master and core cluster services (CoreDNS, KubeDNS).

#### **5. `kubectl api-resources`**
- **Syntax**: `kubectl api-resources [-o wide]`
- **Explanation**: Queries the API server's OpenAPI schema and outputs a complete list of all supported resource kinds, their short names (e.g., `po` for pods, `svc` for services, `netpol` for networkpolicies, `hpa` for horizontalpodautoscalers), API groups (`apps/v1`, `networking.k8s.io/v1`), and whether the resource is namespaced or cluster-scoped.

---

### Level 2: Worker Node Topology & Resource Reservation

#### **1. `kubectl get nodes -o wide`**
- **Syntax**: `kubectl get nodes -o wide`
- **Explanation**: Retrieves all worker nodes. `-o wide` displays `INTERNAL-IP` (VPC private IP), `OS-IMAGE` (e.g. Container-Optimized OS), `KERNEL-VERSION` (e.g. `6.12.85+`), and `CONTAINER-RUNTIME` (`containerd://2.x`).

#### **2. `kubectl get nodes --show-labels`**
- **Syntax**: `kubectl get nodes --show-labels`
- **Explanation**: Dumps all key-value labels assigned to nodes (e.g., `topology.gke.io/zone=us-east4-a`, `node.kubernetes.io/instance-type=n1-standard-1`). Used for `nodeSelector` and `nodeAffinity` scheduling rules.

#### **3. `kubectl top nodes --sort-by=cpu`**
- **Syntax**: `kubectl top nodes --sort-by=cpu`
- **Explanation**: Fetches live compute consumption from Metrics Server. Lists CPU (millicores `m`, where $1000\text{m} = 1\text{ vCPU}$) and RAM (MiB / GiB) per node, sorted from highest consumer to lowest.

#### **4. `kubectl describe node <NODE_NAME>`**
- **Syntax**: `kubectl describe node <NODE_NAME>`
- **Explanation**: Deep-dives into node health:
  - `Allocatable`: Actual capacity available for user pods after subtracting GKE system reservations (`kube-reserved` and `system-reserved`).
  - `Conditions`: Checks `Ready=True`, `MemoryPressure=False`, `DiskPressure=False`, `PIDPressure=False`.
  - `Non-terminated Pods`: Displays the total sum of CPU and memory `requests` and `limits` reserved by active pods on that node.

---

### Level 3: Multi-Container Pod Introspection

#### **1. `kubectl get pods -o wide`**
- **Syntax**: `kubectl get pods [-n <NAMESPACE>] -o wide`
- **Explanation**: Shows Pod IP addresses (`10.100.x.x` secondary VPC range) and the exact worker VM node (`spec.nodeName`) hosting each pod.

#### **2. `kubectl get pods -l tier=tier2`**
- **Syntax**: `kubectl get pods -l <KEY>=<VALUE>`
- **Explanation**: Uses label selectors to filter pods. Essential when scripting rolling deployments or checking specific microservice tiers.

#### **3. `kubectl describe pod <POD_NAME>`**
- **Syntax**: `kubectl describe pod <POD_NAME>`
- **Explanation**: The primary pod diagnostic tool. Inspects:
  - `Init Containers` and `Containers` state (`Waiting`, `Running`, `Terminated`).
  - `Exit Codes`: `0` (clean exit), `1` (application crash), `137` (OOMKilled by Linux kernel), `139` (Segmentation fault).
  - `Events:` chronological audit trail of scheduling, volume mounts, image pulls, and probe failures.

#### **4. `kubectl get pod <POD_NAME> -o jsonpath='{.spec.containers[*].name}'`**
- **Syntax**: `kubectl get pod <POD_NAME> -o jsonpath='<EXPRESSION>'`
- **Explanation**: Extracts specific JSON attributes. This command lists all container names running inside a multi-container pod (e.g. `api-app cloud-sql-proxy`).

---

### Level 4: Live Container Shells, Local Socket Probes & Port-Forwarding

#### **1. `kubectl exec -it <POD_NAME> -c <CONTAINER> -- /bin/sh`**
- **Syntax**: `kubectl exec -it <POD_NAME> -c <CONTAINER> -- /bin/sh`
- **Explanation**: Allocates a pseudo-TTY (`-t`) and keeps stdin open (`-i`) to launch an interactive shell inside the container's isolated Linux namespace.
- **Why use it**: Inspect `/etc/resolv.conf`, verify environment variables (`env`), and test local file permissions.

#### **2. `kubectl exec -it <POD_NAME> -c api-app -- nc -zv 127.0.0.1 5432`**
- **Syntax**: `kubectl exec -it <POD_NAME> -c <CONTAINER> -- nc -zv <HOST> <PORT>`
- **Explanation**: Uses Netcat (`nc`) with zero-I/O mode (`-z`) and verbose output (`-v`) to test if the Cloud SQL Proxy sidecar is actively listening on TCP port 5432 over `127.0.0.1` (localhost).

#### **3. `kubectl exec -it <POD_NAME> -c api-app -- nslookup backend-service`**
- **Syntax**: `kubectl exec -it <POD_NAME> -c <CONTAINER> -- nslookup <SERVICE_NAME>`
- **Explanation**: Tests internal Kubernetes DNS service discovery by querying `node-local-dns` (`169.254.20.10`) or `kube-dns` to verify that service names resolve to their virtual ClusterIPs (`10.101.x.x`).

#### **4. `kubectl port-forward svc/backend-service 8080:8080`**
- **Syntax**: `kubectl port-forward <RESOURCE_TYPE>/<NAME> <LOCAL_PORT>:<REMOTE_PORT>`
- **Explanation**: Opens a local TCP listener on port 8080 and establishes a multiplexed SPDY tunnel through the Kubernetes API server directly into the private ClusterIP service.
- **Why use it**: Test private APIs or database endpoints from your local browser or `curl` without exposing public Load Balancers.

---

### Level 5: Real-Time Log Streaming, Crash Dumps & Cluster Event Auditing

#### **1. `kubectl logs -l app=backend -c cloud-sql-proxy --timestamps=true --tail=30 -f`**
- **Syntax**: `kubectl logs -l <SELECTOR> -c <CONTAINER> --timestamps=true --tail=<N> -f`
- **Explanation**: Streams logs across all pods matching `app=backend`, targeting only the `cloud-sql-proxy` sidecar container. `--timestamps=true` prepends RFC3339 timestamps for log correlation. `-f` follows the live stream.

#### **2. `kubectl logs <POD_NAME> -c api-app --previous`**
- **Syntax**: `kubectl logs <POD_NAME> -c <CONTAINER> --previous`
- **Explanation**: Pulls the log buffer of the **previously terminated container instance** before it crashed. **Essential for debugging `CrashLoopBackOff`.**

#### **3. `kubectl get events --sort-by='.metadata.creationTimestamp'`**
- **Syntax**: `kubectl get events --sort-by='<JSONPATH>'`
- **Explanation**: Retrieves all cluster state change records stored in `etcd` sorted chronologically from oldest to newest.

#### **4. `kubectl get events -A --field-selector type=Warning`**
- **Syntax**: `kubectl get events -A --field-selector type=Warning`
- **Explanation**: Scans all namespaces (`-A`) and filters out routine `Normal` events to isolate critical warnings: `FailedScheduling`, `Unhealthy` probe failures, `FailedMount`, and `OOMKilling`.

---

### Level 6: Advanced JSONPath Expressions & Custom Terminal Dashboards

#### **1. `kubectl get ingress gke-prod-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`**
- **Syntax**: `kubectl get <RESOURCE> -o jsonpath='<QUERY>'`
- **Explanation**: Navigates the JSON object tree and extracts only the assigned external IPv4 address of the Google Cloud Global Application Load Balancer.

#### **2. `kubectl get secret db-credentials -o jsonpath="{.data.password}" | base64 --decode`**
- **Syntax**: `kubectl get secret <NAME> -o jsonpath="{.data.<KEY>}" | base64 --decode`
- **Explanation**: Extracts the base64-encoded secret payload from `etcd` and pipes it directly to `base64 --decode` to view the plaintext database password.

#### **3. `kubectl get pods -o custom-columns=...`**
- **Syntax**: `kubectl get pods -o custom-columns=<COL_NAME>:<JSONPATH>,...`
- **Explanation**: Builds custom terminal dashboards on the fly:
  ```bash
  kubectl get pods -o custom-columns=POD_NAME:.metadata.name,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,MEM_LIMIT:.spec.containers[*].resources.limits.memory,RESTARTS:.status.containerStatuses[*].restartCount,STATUS:.status.phase
  ```

---

### Level 7: Production Chaos, Zero-Downtime Rollouts & HPA Load Testing

#### **1. Zero-Downtime Rolling Update & Rollback**
```bash
# 1. Update container image imperatively
kubectl set image deployment/frontend-deployment nginx-frontend=nginx:1.25.4-alpine

# 2. Watch rolling update progression across ReplicaSets
kubectl rollout status deployment/frontend-deployment

# 3. View deployment revision history
kubectl rollout history deployment/frontend-deployment

# 4. Instant rollback to previous revision
kubectl rollout undo deployment/frontend-deployment
```
- **Under the Hood**: Kubernetes creates a new ReplicaSet (`v2`), provisions new pods, waits for their `readinessProbe` to pass, adds them to the Service Endpoints, and only then terminates pods in the old ReplicaSet (`v1`).

#### **2. Pod Deletion & ReplicaSet Self-Healing**
```bash
# Delete a running pod to test self-healing
TARGET_POD=$(kubectl get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $TARGET_POD
```
- **Under the Hood**: The `kube-controller-manager` runs an infinite control loop ($T_{\text{reconcile}} \approx 100\text{ms}$). When `observedReplicas` ($1$) $<$ `desiredReplicas` ($2$), it immediately issues a `POST /api/v1/pods` request to schedule a replacement pod.

#### **3. Horizontal Pod Autoscaler (HPA) Real-Time Stress Testing**
```bash
# 1. Watch HPA metrics in real time
kubectl get hpa backend-hpa -w &

# 2. Launch 4 parallel authorized stress worker pods (tagged with tier=tier1 to pass NetworkPolicies)
for i in {1..4}; do
  kubectl run stress-worker-$i \
    --image=curlimages/curl:latest \
    --labels="app=frontend,tier=tier1" \
    --restart=Never \
    -- /bin/sh -c "while true; do curl -s http://backend-service:8080/health > /dev/null; done"
done

# 3. Clean up stress workers after scale-up is observed
kubectl delete pod stress-worker-1 stress-worker-2 stress-worker-3 stress-worker-4
```
- **Under the Hood**: Every 15 seconds, HPA queries `metrics-server` for CPU usage. When average CPU exceeds 70%, HPA calculates desired replicas ($\lceil \text{Current} \times \frac{\text{Observed\%}}{\text{Target\%}} \rceil$) and updates the Deployment replica count from 2 up to 10.


