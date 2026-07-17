# Project 1: Containerize & Auto-Deploy Web App (GCP Dedicated)

This guide provides a production-grade, end-to-end implementation of **Project 1** for Google Cloud Platform (GCP). It uses a Node.js web application, containerized using Docker, built and scanned with Cloud Build, stored in Artifact Registry, and deployed serverless to Cloud Run.

---

## 1. Architecture Flow

```
Developer Git Push
       │
       ▼
GCP Cloud Build (Triggered by git push or manual build submit)
       │
 ┌─────┴──────────────────────────────────────────────────────────────────┐
 │ Pipeline (cloudbuild.yaml):                                            │
 │  1. Lint app (ESLint)                                                  │
 │  2. Run Unit Tests (Jest)                                              │
 │  3. Build Multi-stage Docker Image (Optimized/Slim)                    │
 │  4. Scan Image for Vulnerabilities (Trivy Security Gate)               │
 │  5. Push Image to Artifact Registry (Tagged by Git Commit SHA)         │
 │  6. Deploy to Cloud Run (Serverless, Autoscaling, IAM Scoped)          │
 └─────┬──────────────────────────────────────────────────────────────────┘
       │
       ▼
GCP Artifact Registry (Immutable storage)
       │
       ▼
GCP Cloud Run Service
 ┌─────┴──────────────────────────────────────────────────────────────────┐
 │ Features:                                                              │
 │  - Scales 0 to 5 instances (Min/Max limits to avoid cost spikes)       │
 │  - Concurrency: 80 requests per instance                               │
 │  - Startup Probe / Liveness Probe on /health                           │
 │  - Automated Traffic Splitting & Rollback on failure                   │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Directory Structure

Create the following file structure locally or in your repository:
```
project-1/
├── app/
│   ├── package.json
│   ├── server.js
│   ├── Dockerfile
│   └── .dockerignore
└── cloudbuild.yaml
```

---

## 3. Implementation Code

### File: `app/package.json`
Defines the dependencies, test commands, and lint scripts.
```json
{
  "name": "gcp-devops-p1",
  "version": "1.0.0",
  "description": "Production ready Node.js app for GCP Cloud Run deployment",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "test": "jest --passWithNoTests",
    "lint": "eslint ."
  },
  "dependencies": {
    "express": "^4.19.2"
  },
  "devDependencies": {
    "eslint": "^8.57.0",
    "jest": "^29.7.0",
    "supertest": "^6.3.4"
  }
}
```

### File: `app/server.js`
A basic Node.js API with a JSON endpoint and a proper health check routing path.
```javascript
const express = require('express');
const app = express();
const PORT = process.env.PORT || 8080;

app.get('/', (req, res) => {
  res.json({
    status: "Healthy",
    message: "Welcome to Project 1 on GCP!",
    timestamp: new Date(),
    version: process.env.K_REVISION || "local"
  });
});

// Explicit health check endpoint for Cloud Run Startup/Liveness probe
app.get('/health', (req, res) => {
  res.status(200).json({ status: "UP" });
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`Application listening on port ${PORT}`);
});

module.exports = server;
```

### File: `app/.dockerignore`
Prevents local builds, secrets, and system files from leaking into the container context.
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

### File: `app/Dockerfile`
A highly optimized, multi-stage Dockerfile adhering to industry security standards.
- **Stage 1 (Builder):** Uses a complete Node.js image to install dependencies and run build tools.
- **Stage 2 (Runtime):** Uses a slim alpine runtime, copies only the required files, runs as a non-privileged `node` user, and exposes the port.

```dockerfile
# Stage 1: Build & Package
FROM node:20-alpine AS builder
WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Runtime Release
FROM node:20-alpine
WORKDIR /usr/src/app

# Security Hardening: Upgrade OS libraries to patch CVEs (e.g. openssl)
RUN apk update && apk upgrade --no-cache

# Run as non-root user
USER node

# Copy dependencies and source code from Stage 1 builder
COPY --chown=node:node --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=node:node . .

# Set environment to production
ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

# Health check check-in logic inside container (fallback check)
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
```

### File: `cloudbuild.yaml`
Automated pipeline configuration specifying stages, parameters, and a security scanning step using **Trivy**.
```yaml
steps:
  # 1. Install devDependencies and run Tests/Linting
  - name: 'node:20-alpine'
    entrypoint: 'npm'
    args: ['install']
    dir: 'app'
    id: 'Install Dev Dependencies'

  - name: 'node:20-alpine'
    entrypoint: 'npm'
    args: ['run', 'test']
    dir: 'app'
    id: 'Run Unit Tests'

  # 2. Build Docker Container using cache-from to optimize compile speeds
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-t'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app:$_IMAGE_TAG'
      - './app'
    id: 'Build Container'

  # 3. Vulnerability Security Scan using Trivy
  - name: 'aquasec/trivy:latest'
    args:
      - 'image'
      - '--exit-code'
      - '1' # Fail the build pipeline if CRITICAL issues are discovered
      - '--severity'
      - 'CRITICAL'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app:$_IMAGE_TAG'
    id: 'Security Vulnerability Scan'

  # 4. Push Container Image to Google Artifact Registry
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'push'
      - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app:$_IMAGE_TAG'
    id: 'Push to Artifact Registry'

  # 5. Deploy Serverless Endpoint to Cloud Run
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'run'
      - 'deploy'
      - '$_SERVICE_NAME'
      - '--image=$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app:$_IMAGE_TAG'
      - '--region=$_DEPLOY_REGION'
      - '--platform=managed'
      - '--allow-unauthenticated' # Set to false if API is private/internal
      - '--port=8080'
      - '--min-instances=0' # Scale to zero when idle to minimize cost
      - '--max-instances=5' # Cost guardrail
      - '--concurrency=80' # Request capacity per container before scaling
      - '--cpu-throttling' # Throttle CPU when idle to optimize costs
    id: 'Deploy to Cloud Run'

# Default Substitutions (Can be overridden in triggers)
substitutions:
  _GAR_REGION: 'us-central1'
  _GAR_REPO: 'devops-portfolio'
  _SERVICE_NAME: 'web-service'
  _DEPLOY_REGION: 'us-central1'
  _IMAGE_TAG: 'latest'

# Docker images built in the pipeline are tracked
images:
  - '$_GAR_REGION-docker.pkg.dev/$PROJECT_ID/$_GAR_REPO/app:$_IMAGE_TAG'

options:
  logging: CLOUD_LOGGING_ONLY
```

---

## 4. End-to-End Implementation Steps

Execute the following commands in the terminal using the `gcloud` CLI to provision resources and run the build:

### Step 1: Set Variables
```bash
export PROJECT_ID=$(gcloud config get-value project)
export REGION="us-central1"
export REPO_NAME="devops-portfolio"
export SERVICE_NAME="web-service"
```

### Step 2: Enable GCP APIs
Enable the necessary services for registry storage, pipeline triggering, and compute hosting:
```bash
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  containeranalysis.googleapis.com
```

### Step 3: Create Artifact Registry
```bash
gcloud artifacts repositories create $REPO_NAME \
    --repository-format=docker \
    --location=$REGION \
    --description="Docker repository for DevOps Portfolio apps"
```

### Step 4: Configure Cloud Build Service Account Permissions
Cloud Build needs permissions to write to Artifact Registry and deploy to Cloud Run.
```bash
# Get Project Number
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Grant Cloud Run Admin Role to the Cloud Build Service Account
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com" \
    --role="roles/run.admin"

# Grant IAM Service Account User to act as default runtime identity
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser"

# Grant Storage Admin to the default Compute Engine service account executing the CLI
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/storage.admin"

# Grant Artifact Registry Writer to the default Compute Engine service account executing the build
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/artifactregistry.writer"

# Grant Cloud Run Admin to the default Compute Engine service account executing the deploy step
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/run.admin"

# Grant IAM Service Account User to the default Compute Engine service account to assign runtime service accounts
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser"
```

### Step 5: Run the Deployment Pipeline
Trigger a manual build to verify the code containerizes, scans, and deploys correctly:
```bash
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_GAR_REGION=$REGION,_GAR_REPO=$REPO_NAME,_SERVICE_NAME=$SERVICE_NAME,_DEPLOY_REGION=$REGION
```

---

## 5. "Break & Learn" Test Cases (Interactive Interview Debugging Lab)

Use these 9 interactive debugging labs to intentionally break your deployment, observe the error messages, learn the underlying DevOps/GCP architecture concepts, and fix them.

---

### Case 1: The "Exec Format" CPU Architecture Crash
> [!WARNING]
> **Interview Context:** "Your container builds and runs perfectly on your developer workstation, but instantly enters a crash loop or exits with a low-level error code when deployed to a GCP virtual machine or serverless compute."

* **How to Break:**
  Build the image locally on an ARM-based computer (like an Apple Silicon M1/M2/M3 MacBook) and push it directly to Artifact Registry, then deploy it manually:
  ```bash
  # Run this on an ARM machine
  docker build -t $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/app:arm-broken ./app
  docker push $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/app:arm-broken
  gcloud run deploy web-service --image=$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/app:arm-broken --region=$REGION --platform=managed
  ```
* **The Symptoms:**
  Cloud Run logs show the service failing to start with:
  `standard_init_linux.go:228: exec user process caused: exec format error`
* **The Learn:**
  Docker containers share the host kernel. Code compiled for an ARM64 architecture cannot run on the standard AMD64 (x86_64) CPU architectures utilized by GCP Cloud Run instances unless run through an emulation layer.
* **How to Fix:**
  Force the Docker build tool to target standard Linux AMD64 architecture:
  ```bash
  docker buildx build --platform linux/amd64 -t $REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/app:latest --push ./app
  ```

---

### Case 2: The Port Mismatch Silence
> [!WARNING]
> **Interview Context:** "Your application starts up successfully and logs 'Listening on Port 3000', but Cloud Run returns a 502 Bad Gateway and reports a failed startup check. Why?"

* **How to Break:**
  1. Edit `app/server.js` and change `PORT = process.env.PORT || 8080` to `PORT = 3000`.
  2. Deploy this container configuration while keeping Cloud Run's port setting at the default `8080`.
* **The Symptoms:**
  Cloud Run deployment fails with:
  `Cloud Run error: Container failed to start. Failed to start and then listen on the port defined by the PORT environment variable.`
* **The Learn:**
  Cloud Run passes a dynamic `PORT` environment variable to the container (defaulting to `8080`) and listens on that port. If you hardcode a different port (like `3000`), Cloud Run's routing plane will send health checks to `8080`, receive no response, and declare the container dead.
* **How to Fix:**
  Restore the port assignment to rely on the environment variable inside `app/server.js`:
  ```javascript
  const PORT = process.env.PORT || 8080;
  ```

---

### Case 3: Pipeline IAM Access Denied
> [!WARNING]
> **Interview Context:** "You set up a brand new Cloud Build pipeline, but it fails at the deployment step with a 403 Permission Denied on the Cloud Run API. How do you resolve this?"

* **How to Break:**
  Remove the Cloud Run Admin role from the Cloud Build service account:
  ```bash
  PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
  
  gcloud projects remove-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com" \
      --role="roles/run.admin"
  ```
  Run the build submit.
* **The Symptoms:**
  The Cloud Build pipeline logs show:
  `ERROR: (gcloud.run.deploy) PERMISSION_DENIED: Permission 'run.services.create' denied on resource 'projects/...`
* **The Learn:**
  Google Cloud follows least-privilege security model. Cloud Build's automated worker identities do not have rights to deploy services to compute environments unless they are explicitly bound to those roles via Cloud IAM.
* **How to Fix:**
  Bind the Cloud Run Admin role back to the Cloud Build service account:
  ```bash
  gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER@cloudbuild.gserviceaccount.com" \
      --role="roles/run.admin"
  ```

---

### Case 4: The Trivy Scanner Security Gate
> [!WARNING]
> **Interview Context:** "A security audit requires container images to have zero HIGH/CRITICAL vulnerabilities. How do you build a pipeline check that automatically blocks deployment if a package is insecure?"

* **How to Break:**
  1. Change the base image in `app/Dockerfile` to an old, unpatched version of node (e.g., `FROM node:14`).
  2. Temporarily set `--severity HIGH,CRITICAL` in your `cloudbuild.yaml` Trivy step.
  3. Submit the build.
* **The Symptoms:**
  The build fails during the `Security Vulnerability Scan` stage with a summary table listing CVEs and returns:
  `Step #3 - "Security Vulnerability Scan": Error: exit status 1`
* **The Learn:**
  By running Trivy with the `--exit-code 1` parameter, any vulnerability discovered above your set threshold causes the build container to return exit code 1, which signals Cloud Build to stop executing and skip the deployment stage.
* **How to Fix:**
  Use secure, updated base images (like `node:20-alpine`) and run OS updates (`apk update && apk upgrade`) to resolve outstanding CVEs before switching users in the Dockerfile.

---

### Case 5: Container Cold Start and Aggressive Healthchecks
> [!WARNING]
> **Interview Context:** "Your application starts up successfully in development, but under serverless configurations, it crashes during cold-starts. How do you mitigate startup latency issues?"

* **How to Break:**
  1. Add a heavy, blocking synchronous loop at the global scope of your `app/server.js` (e.g., a loop calculating Fibonacci numbers that takes 25 seconds before calling `app.listen`).
  2. Deploy to Cloud Run.
* **The Symptoms:**
  Client requests time out and Cloud Run logs report:
  `Container startup health check failed. Revision crashed.`
* **The Learn:**
  When scaling from 0 to 1 instance (a cold start), Cloud Run expects the container to start listening for HTTP traffic within a defined health check timeout window. Synchronous startup logic blocks the event loop, causing health check failures.
* **How to Fix:**
  Optimize startup code to load asynchronously after the port is bound, increase the Cloud Run startup timeout limits using `--startup-cpu-boost`, or increase the initial delay parameters.

---

### Case 6: Cloud Storage Bucket Access Denied (gcloud builds submit 403)
> [!WARNING]
> **Interview Context:** "When running a manual build via `gcloud builds submit`, the operation aborts immediately before compiling any code with a Storage Object get/write error. Why?"

* **How to Break:**
  Remove the Storage Admin permission from your local CLI's active identity:
  ```bash
  gcloud projects remove-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
      --role="roles/storage.admin"
  ```
  Submit the build.
* **The Symptoms:**
  `ERROR: (gcloud.builds.submit) INVALID_ARGUMENT: could not resolve source: googleapi: Error 403: ... does not have storage.objects.get access...`
* **The Learn:**
  `gcloud builds submit` compresses your project directory and uploads it as a tarball to a Google Cloud Storage bucket (`gs://[PROJECT_ID]_cloudbuild/`). The identity submitting the build needs Storage Object Creator/Viewer rights on that bucket.
* **How to Fix:**
  Restore the Storage Admin role to the active identity:
  ```bash
  gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
      --role="roles/storage.admin"
  ```

---

### Case 7: The "Empty Tag" Substitution Parser Error
> [!WARNING]
> **Interview Context:** "You reference `$SHORT_SHA` to tag your built images in your build configuration yaml, but manual runs fail immediately during syntax parsing. How do you resolve this?"

* **How to Break:**
  1. Modify `cloudbuild.yaml` to reference `$SHORT_SHA` in the build image tags instead of `$_IMAGE_TAG`.
  2. Run `gcloud builds submit` in a directory that is not a git repository (or delete the local `.git` directory).
* **The Symptoms:**
  `ERROR: (gcloud.builds.submit) INVALID_ARGUMENT: invalid build: invalid image name ".../app:": could not parse reference...`
* **The Learn:**
  Native Cloud Build variables like `$SHORT_SHA` are only populated for automated triggers linked to a VCS provider. For manual `gcloud builds submit` runs, it resolves to empty, creating an invalid image tag name.
* **How to Fix:**
  Wrap variable tagging inside custom user-defined substitutions (like `$_IMAGE_TAG`) that have a fallback default value (like `latest`) defined in the `substitutions:` block of the yaml.

---

### Case 8: Subdirectory Build Context Mismatch (NPM Exit 254)
> [!WARNING]
> **Interview Context:** "Your code files are nested inside a subdirectory like `/app`. When your pipeline runs `npm install`, the build environment instantly crashes. Why?"

* **How to Break:**
  1. Remove the `dir: 'app'` lines from the `npm install` and `npm run test` steps in `cloudbuild.yaml`.
  2. Run the build.
* **The Symptoms:**
  `BUILD FAILURE: Build step failure: build step 0 "node:20-alpine" failed: step exited with non-zero status: 254`
* **The Learn:**
  By default, all Cloud Build steps run inside the root workspace folder `/workspace`. If your application code and `package.json` are inside a subdirectory, npm fails to find the package manifests and exits with an error code.
* **How to Fix:**
  Add the `dir` configuration parameter pointing to the subdirectory for all command steps running inside that subfolder:
  ```yaml
  dir: 'app'
  ```

---

### Case 9: Service Account Identity Confusion (Compute default vs. Cloud Build default)
> [!WARNING]
> **Interview Context:** "You granted Cloud Run Admin role to the default Cloud Build service account `[PROJECT_NUMBER]@cloudbuild.gserviceaccount.com`, but the pipeline still fails at the deploy step with a 403 Permission Denied on `namespaces/.../services/...` using the Compute Engine service account instead. Why?"

* **How to Break:**
  Remove the permissions from the Compute Engine default service account:
  ```bash
  gcloud projects remove-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
      --role="roles/run.admin"
  ```
  Submit the build.
* **The Symptoms:**
  `PERMISSION_DENIED: Permission 'run.services.get' denied on resource 'namespaces/.../services/web-service'... authenticated as ...-compute@developer.gserviceaccount.com`
* **The Learn:**
  Modern Google Cloud configurations run Cloud Build pipeline steps using the default Compute Engine service account (`[PROJECT_NUMBER]-compute@developer.gserviceaccount.com`) instead of the legacy Cloud Build service account. Therefore, pipeline steps executing deployment tasks will fail unless this specific account has IAM roles assigned.
* **How to Fix:**
  Grant the roles to the Compute Engine default service account:
  ```bash
  gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
      --role="roles/run.admin"
  ```
