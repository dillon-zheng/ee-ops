# Artifact Registry Runbook (CI Dependency Cache)

Overview
- Artifact Registry (AR) can be used for two distinct purposes in CI:
  - OCI artifacts produced by CI (images, packages, etc.): Standard repositories (read/write).
  - Third-party dependency caching (pull-through cache): Remote repositories (read-only cache from upstream) + optionally Virtual repositories (aggregate).
- In the legacy clusters we also run:
  - `goproxy.apps.svc` (a Kubernetes `goproxy/goproxy` deployment) for Go module caching.
  - `zot` as an on-demand mirror of Artifact Registry for non-GCP environments.
- In GCP, prefer direct access to AR via Workload Identity + Private Google Access to remove extra proxy/mirror layers.

Scope
- This runbook focuses on the "dependency cache" use case (remote repos for Docker Hub and `proxy.golang.org`).
- Bazel remote cache (AC/CAS) is handled separately via a GCS bucket.

Current state (evidence anchors)
- Jenkins global `GOPROXY` (both prod/prod2):
  - `apps/prod/jenkins/release/values-JCasC.yaml#L283`
  - `apps/prod2/jenkins/beta/release/values-JCasC.yaml#L307`
- In-cluster Go proxy deployment:
  - `apps/prod/goproxy/deployment.yaml#L17-L45` (upstream `https://proxy.golang.org`, `emptyDir` cache)
- On-demand mirror of Artifact Registry (for non-GCP envs):
  - `apps/prod2/zot/config/config.json#L93-L125` (sync from `https://us-docker.pkg.dev`)
- CI already uses Artifact Registry as an OCI host:
  - PingCAP-QE/ci: `prow-jobs/pingcap-inc/tici/presubmits.yaml#L98-L99` sets `OCI_ARTIFACT_HOST=us-docker.pkg.dev/pingcap-testing-account/hub`

Design goals
- Correctness: no change in build outputs, only change download endpoints.
- Stability: reduce external network flakiness and rate limits.
- Simplicity: remove Kubernetes-managed dependency proxies (goproxy/zot mirror) for GCP-based jobs.
- Security: least privilege by default; allow read-only anonymous access only for selected cache repos (current: `ghcr-remote`) when needed for migration simplicity.
- Batch migration: allow switching per environment (GCP jobs first; legacy jobs can keep old endpoints temporarily).

Repository plan (recommended)
- Keep existing OCI repos as-is (examples observed in CI config):
  - `hub`, `dev`, `tidbx`, `internal`, `hotfix` (all under `us-docker.pkg.dev/pingcap-testing-account/...`)
- Add remote repositories for third-party caches:
  - Go modules (remote repo):
    - Format: `go`
    - Mode: `remote-repository`
    - Upstream: `https://proxy.golang.org/` (the only supported upstream)
  - Docker Hub (remote repo):
    - Format: `docker`
    - Mode: `remote-repository`
    - Upstream: `docker-hub`
    - Optional: configure upstream credentials to avoid unauthenticated rate limits.
- Optional: add Docker virtual repo to aggregate standard + remote repos (if you want a single hostname/repo prefix).

Location strategy
- You must pick a location per repository.
- If you already have widely-used repos under `us` (multi-region), creating new repos in the same `us` location avoids mixing hostnames.
  - Hostname pattern: `us-<format>.pkg.dev` (e.g. `us-docker.pkg.dev`, `us-go.pkg.dev`)
- If you are starting fresh, prefer the same region as your GKE cluster (e.g. `us-central1`) for latency/cost.
  - Hostname pattern: `<region>-<format>.pkg.dev` (e.g. `us-central1-docker.pkg.dev`, `us-central1-go.pkg.dev`)

IAM model (current state + recommended baseline)
- Current state for remote cache repos:
  - `ghcr-remote`, `dockerhub-remote`, and `go-proxy-remote` are configured with repo-level anonymous read:
    - Principal: `allUsers`
    - Role: `roles/artifactregistry.reader`
  - This allows transparent read access from CI jobs without per-job credential bootstrap.
  - For Kubernetes `spec.containers[].image` pulls, this also avoids node-SA reader grants for these public-read repos.
- Baseline for all other repos (standard repos and any write path):
  - Use authenticated access via service accounts.
  - Prefer Workload Identity for in-pod clients (`go`, `docker`, `buildx`, `kaniko`).
  - For kubelet image pulls, use node SA permissions (pod Workload Identity does not apply to kubelet).
- Common roles:
  - Read from AR: `roles/artifactregistry.reader`
  - Write to AR (push/publish): `roles/artifactregistry.writer`
  - Admin (repo/create/policy): `roles/artifactregistry.admin`

Remote upstream credentials (important)
- For Docker remote repos that need upstream authentication (Docker Hub / GHCR / custom registry):
  - Store the upstream password/token in Secret Manager.
  - When creating the remote repo, reference the secret version via `--remote-password-secret-version`.
  - Grant the Artifact Registry service agent access to that secret:
    - Member: `serviceAccount:service-<PROJECT_NUMBER>@gcp-sa-artifactregistry.iam.gserviceaccount.com`
  - Role: `roles/secretmanager.secretAccessor`
  - Without this binding, the remote repo will be created but upstream auth will fail at runtime.

Create repositories (Console)
Recommended values for our current migration batch
- Project: `pingcap-testing-account`
- Location: `us` (align with existing `us-docker.pkg.dev` endpoints to avoid mixed hostnames)
- Repository ID for GHCR cache: `ghcr-remote`
- Format: `Docker`
- Mode: `Remote`
- Upstream: custom URL `https://ghcr.io`

Create GHCR remote repository in Console (step-by-step)
1. Open Google Cloud Console -> Artifact Registry -> Repositories.
2. Ensure project is `pingcap-testing-account`.
3. Click `Create repository`.
4. Fill basic fields:
   - Name: `ghcr-remote`
   - Format: `Docker`
   - Mode: `Remote`
   - Location type/location: `us` (multi-region)
   - Description (optional): `GHCR pull-through cache for CI`
5. In upstream settings:
   - Select custom upstream for Docker.
   - Upstream URL: `https://ghcr.io`
6. Authentication for upstream:
   - Initial bring-up can use anonymous upstream access.
   - If needed later, switch to authenticated upstream with Secret Manager token.
7. Encryption/network:
   - Keep Google-managed encryption key unless there is a KMS compliance requirement.
   - Access policy choice:
     - Strict mode: keep private repo and grant node SA/GSA readers.
     - Current migration mode (this repo): add repo-level `allUsers -> roles/artifactregistry.reader`.
8. Click `Create`.
9. Verify repository details page shows:
   - Format `Docker`
   - Mode `Remote`
   - Upstream `https://ghcr.io`

How to use the new GHCR remote repo
- Endpoint format:
  - `us-docker.pkg.dev/pingcap-testing-account/ghcr-remote/<image-path>:<tag>`
- Rewrite example:
  - Old: `ghcr.io/pingcap-qe/cd/utils/release:v2025.10.12-7-gfdd779c`
  - New: `us-docker.pkg.dev/pingcap-testing-account/ghcr-remote/pingcap-qe/cd/utils/release:v2025.10.12-7-gfdd779c`
- Behavior:
  - First pull is cache-miss (AR fetches from `ghcr.io`).
  - Subsequent pulls are served from Artifact Registry cache.

Create Docker Hub remote repository in Console (same policy as GHCR)
Recommended values
- Repository ID: `dockerhub-remote`
- Format: `Docker`
- Mode: `Remote`
- Upstream: `docker-hub`
- Access mode: repo-level `allUsers -> roles/artifactregistry.reader` (same as `ghcr-remote`)

Step-by-step
1. Open Artifact Registry -> Repositories -> `Create repository`.
2. Fill basic fields:
   - Name: `dockerhub-remote`
   - Format: `Docker`
   - Mode: `Remote`
   - Location: `us`
   - Description (optional): `Docker Hub pull-through cache for CI`
3. Upstream settings:
   - Select Docker upstream preset `docker-hub` (not custom URL).
4. Upstream auth:
   - Initial phase can use anonymous upstream access.
   - If Docker Hub rate-limit becomes an issue, add upstream credentials via Secret Manager.
5. Access policy (match current GHCR choice):
   - Permissions -> Grant access.
   - Principal: `allUsers`
   - Role: `Artifact Registry Reader`.
6. Verify details page:
   - Format `Docker`
   - Mode `Remote`
   - Upstream `docker-hub`

How to use the new Docker Hub remote repo
- Endpoint format:
  - `us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote/<image-path>:<tag>`
- Rewrite examples:
  - Old: `docker:20.10.17-dind`
  - New: `us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote/library/docker:20.10.17-dind`
  - Old: `alpine:3.20`
  - New: `us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote/library/alpine:3.20`
- Note:
  - Docker Hub "official images" need the `library/` prefix when written as full path.

Create Go remote repository in Console (same policy as GHCR/Docker Hub)
Recommended values
- Repository ID: `go-proxy-remote`
- Format: `Go`
- Mode: `Remote`
- Upstream: `https://proxy.golang.org/` (only supported upstream)
- Access mode: repo-level `allUsers -> roles/artifactregistry.reader`

Step-by-step
1. Open Artifact Registry -> Repositories -> `Create repository`.
2. Fill basic fields:
   - Name: `go-proxy-remote`
   - Format: `Go`
   - Mode: `Remote`
   - Location: `us`
   - Description (optional): `Go module proxy cache for CI`
3. Upstream settings:
   - Upstream URL: `https://proxy.golang.org/`
4. Access policy:
   - Permissions -> Grant access.
   - Principal: `allUsers`
   - Role: `Artifact Registry Reader`.
5. Verify details page:
   - Format `Go`
   - Mode `Remote`
   - Upstream `https://proxy.golang.org`

How to use the new Go remote repo
- Recommended `GOPROXY`:
  - `https://us-go.pkg.dev/pingcap-testing-account/go-proxy-remote,https://proxy.golang.org,direct`
- Note:
  - This covers normal `go mod`/`go list` module downloads.
  - Bazel `go_repository` URLs in `WORKSPACE/DEPS.bzl` are a separate path and are not automatically switched by `GOPROXY`.

Post-create IAM checks (required for kubelet image pulls)
- If repo is private, grant the GKE node service account read access to this repo (or project-level reader):
  - Role: `roles/artifactregistry.reader`
- Note:
  - Pod Workload Identity does not control kubelet image pulls for `spec.containers[].image`.
  - If repo is private and node SA lacks reader role, pod image pull will fail.

Validate GHCR remote repo (commands we used in practice)
1. Confirm IAM binding includes anonymous read (`allUsers`):
```bash
gcloud artifacts repositories get-iam-policy ghcr-remote \
  --project=pingcap-testing-account \
  --location=us \
  --format=json
```
Expected in output:
- `"role": "roles/artifactregistry.reader"`
- `"members": ["allUsers"]`

2. Find usable CI namespace (if `jenkins-tidb` does not exist):
```bash
kubectl get ns -o name
```

3. Run smoke test pod (example uses `jenkins` namespace):
```bash
kubectl -n jenkins delete pod ghcr-remote-smoke --ignore-not-found=true
kubectl -n jenkins run ghcr-remote-smoke \
  --image=us-docker.pkg.dev/pingcap-testing-account/ghcr-remote/pingcap-qe/cd/utils/release:v2025.10.12-7-gfdd779c \
  --restart=Never \
  --command -- sh -c 'echo ok && sleep 5'
kubectl -n jenkins wait --for=condition=Ready pod/ghcr-remote-smoke --timeout=180s
```

4. Inspect pull events and container output:
```bash
kubectl -n jenkins get pod ghcr-remote-smoke -o wide
kubectl -n jenkins describe pod ghcr-remote-smoke
kubectl -n jenkins logs ghcr-remote-smoke
```

5. Pass criteria:
   - Pod reaches `Completed` or `Running`.
   - `describe` events show `Pulling` then `Successfully pulled`.
   - No `ErrImagePull` / `ImagePullBackOff` / `403`.

6. Verify cache materialization:
   - Artifact Registry -> `ghcr-remote` -> Packages shows package path
     `pingcap-qe/cd/utils/release` after first successful pull.

7. Cleanup:
```bash
kubectl -n jenkins delete pod ghcr-remote-smoke
```

Validate Docker Hub remote repo (run after repo creation)
1. Confirm IAM binding includes anonymous read (`allUsers`):
```bash
gcloud artifacts repositories get-iam-policy dockerhub-remote \
  --project=pingcap-testing-account \
  --location=us \
  --format=json
```
Expected in output:
- `"role": "roles/artifactregistry.reader"`
- `"members": ["allUsers"]`

2. Run smoke test pod:
```bash
kubectl -n jenkins delete pod dockerhub-remote-smoke --ignore-not-found=true
kubectl -n jenkins run dockerhub-remote-smoke \
  --image=us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote/library/alpine:3.20 \
  --restart=Never \
  --command -- sh -c 'echo ok && sleep 5'
kubectl -n jenkins wait --for=condition=Ready pod/dockerhub-remote-smoke --timeout=180s
```

3. Inspect events/output:
```bash
kubectl -n jenkins get pod dockerhub-remote-smoke -o wide
kubectl -n jenkins describe pod dockerhub-remote-smoke
kubectl -n jenkins logs dockerhub-remote-smoke
```

4. Pass criteria:
   - Pod reaches `Completed` or `Running`.
   - `describe` events show `Pulling` then `Successfully pulled`.
   - No `ErrImagePull` / `ImagePullBackOff` / `429`.

5. Verify cache materialization:
   - Artifact Registry -> `dockerhub-remote` -> Packages shows `library/alpine`.
   - Optional CLI check:
```bash
gcloud artifacts docker images list \
  us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote \
  --include-tags \
  --format='table(package,version,tags)'
```

6. Cleanup:
```bash
kubectl -n jenkins delete pod dockerhub-remote-smoke
```

Validate Go remote repo (commands we used in practice)
1. Confirm repo IAM has anonymous read (`allUsers`):
```bash
gcloud artifacts repositories get-iam-policy go-proxy-remote \
  --project=pingcap-testing-account \
  --location=us \
  --format=json
```
Expected in output:
- `"role": "roles/artifactregistry.reader"`
- `"members": ["allUsers"]`

2. Confirm repo mode/upstream:
```bash
gcloud artifacts repositories describe go-proxy-remote \
  --project=pingcap-testing-account \
  --location=us \
  --format='yaml(name,format,mode,remoteRepositoryConfig)'
```
Expected in output:
- `format: GO`
- `mode: REMOTE_REPOSITORY`
- `remoteRepositoryConfig.commonRepository.uri: https://proxy.golang.org`

3. Run cluster smoke test with a public module:
```bash
kubectl -n jenkins delete pod go-gar-smoke --ignore-not-found=true
kubectl -n jenkins run go-gar-smoke \
  --image=us-docker.pkg.dev/pingcap-testing-account/dockerhub-remote/library/golang:1.25-alpine \
  --restart=Never \
  --command -- sh -c 'GOPROXY="https://us-go.pkg.dev/pingcap-testing-account/go-proxy-remote,https://proxy.golang.org,direct" GO111MODULE=on GOMODCACHE=/tmp/modcache go list -m -json github.com/stretchr/testify@v1.9.0'
kubectl -n jenkins logs go-gar-smoke
kubectl -n jenkins describe pod go-gar-smoke
```

4. Pass criteria:
   - `go list` returns module metadata JSON.
   - Pod exits with `Exit Code: 0`.
   - No module download/auth errors in logs/events.

5. Verify cache materialization:
```bash
gcloud artifacts packages list \
  --project=pingcap-testing-account \
  --location=us \
  --repository=go-proxy-remote \
  --format='table(name)'
```
Expected to include package path (example): `github.com/stretchr/testify`.

6. Cleanup:
```bash
kubectl -n jenkins delete pod go-gar-smoke
```

Common failure mapping
- `403` or `denied` during pull:
  - Node service account missing `Artifact Registry Reader`.
- `manifest unknown`:
  - Image path/tag in remote URL is incorrect.
- `upstream fetch failed`:
  - Upstream connectivity/auth issue between Artifact Registry and `ghcr.io`.
- `go: ... us-go.pkg.dev ... no such host`:
  - DNS/network path to GAR endpoint is unavailable in the current runtime environment.
- `go: ... 401/403`:
  - Repo is private and client has no valid auth; either add auth helper or switch to repo-level public read for migration.

Create repositories (CLI)
Prereqs
- `gcloud` installed
- Permissions in the target project:
  - `artifactregistry.repositories.create`
  - (Optional) Secret Manager permissions if configuring upstream auth
- If your local gcloud config dir is not writable, set:
  - `export CLOUDSDK_CONFIG=/tmp/gcloud`

Enable APIs
```bash
export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/tmp/gcloud}"
export PROJECT_ID="pingcap-testing-account"

gcloud services enable \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project="${PROJECT_ID}"
```

Create Go remote repository (proxy.golang.org cache)
```bash
export LOCATION="us-central1"  # or "us"
export GO_REMOTE_REPO="go-proxy-remote"

gcloud artifacts repositories create "${GO_REMOTE_REPO}" \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --repository-format=go \
  --mode=remote-repository \
  --remote-go-repo="https://proxy.golang.org/"
```

Create Docker Hub remote repository (pull-through cache)
```bash
export LOCATION="us-central1"  # or "us"
export DOCKERHUB_REMOTE_REPO="dockerhub-remote"

gcloud artifacts repositories create "${DOCKERHUB_REMOTE_REPO}" \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --repository-format=docker \
  --mode=remote-repository \
  --remote-docker-repo="docker-hub"
```

Optional: configure Docker Hub upstream credentials
Notes
- This is optional for functionality but recommended to reduce rate-limit failures.
- Store the token in Secret Manager and reference it when creating (or updating) the repo.

Example (create secret)
```bash
export DOCKERHUB_USERNAME="<dockerhub-user>"
export DOCKERHUB_TOKEN_SECRET="dockerhub-token"

echo -n "<dockerhub-token>" | gcloud secrets create "${DOCKERHUB_TOKEN_SECRET}" \
  --project="${PROJECT_ID}" \
  --replication-policy="automatic" \
  --data-file=-
```

Create repo with upstream auth (example)
```bash
export DOCKERHUB_TOKEN_SECRET_VERSION="projects/${PROJECT_ID}/secrets/${DOCKERHUB_TOKEN_SECRET}/versions/latest"

gcloud artifacts repositories create "${DOCKERHUB_REMOTE_REPO}" \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --repository-format=docker \
  --mode=remote-repository \
  --remote-docker-repo="docker-hub" \
  --remote-username="${DOCKERHUB_USERNAME}" \
  --remote-password-secret-version="${DOCKERHUB_TOKEN_SECRET_VERSION}"
```

Go client configuration (CI jobs)
Two operating modes
- Public-read mode (current remote cache repos):
  - If repo has `allUsers -> roles/artifactregistry.reader`, Go clients can read without auth bootstrap.
- Private mode (recommended long-term for stricter access):
  - Artifact Registry requires authentication.
  - The `go` command talks to a module proxy over HTTPS; it does not automatically use GCP ADC.
  - Use Google's credential helper to populate `~/.netrc` (works well with Workload Identity).

Minimal job bootstrap (per CI container)
- Set `GOPROXY` to include AR first, then upstream proxy, then direct fallback.
- If repo is private, run the credential helper to configure auth for the AR hostname.

Example (environment variables)
```bash
export PROJECT_ID="pingcap-testing-account"
export LOCATION="us-central1" # or "us"
export GO_REMOTE_REPO="go-proxy-remote"

export GOPROXY="https://${LOCATION}-go.pkg.dev/${PROJECT_ID}/${GO_REMOTE_REPO},https://proxy.golang.org,direct"
```

Example (credential helper for private mode)
```bash
# Use the module-based helper; pin a version for repeatability.
GO_AUTH_TOOL_VERSION="v0.4.0"

# Configure netrc for the AR hostname. This uses ADC (Workload Identity on GKE).
go run "github.com/GoogleCloudPlatform/artifact-registry-go-tools/cmd/auth@${GO_AUTH_TOOL_VERSION}" \
  add-locations --locations="${LOCATION}"

# Refresh token (recommended per job start).
go run "github.com/GoogleCloudPlatform/artifact-registry-go-tools/cmd/auth@${GO_AUTH_TOOL_VERSION}" \
  refresh
```

If you want to avoid `go run` in every job (private mode)
- Bake the helper binary into your CI base image and call it directly.
- Or keep the existing in-cluster `goproxy.apps.svc` for the first migration batch, then switch to AR later.

Docker client configuration (CI jobs)
- Pulling images in Kubernetes (`spec.containers[].image`) is done by the node/kubelet, not by the workload identity of the pod.
  - Ensure the GKE node service account has `roles/artifactregistry.reader` on the relevant docker repos.
- If you use `docker` / `buildx` / `kaniko` inside a pod to push/pull, authenticate inside the pod (Workload Identity or credential helper).

Cleanup / lifecycle
- Artifact Registry supports cleanup policies, but they are typically based on artifact age (time since upload), not "last accessed".
- For remote repositories used as caches, start without aggressive cleanup, observe growth, then add policies if needed.

Migration steps (suggested)
1. Create the remote repositories (Go + Docker Hub).
2. Create a dedicated GSA for CI jobs and grant `roles/artifactregistry.reader` to it (repo-level).
3. Workload Identity:
   - Annotate the CI namespace KSA (or the specific KSA used by jobs) to impersonate the GSA.
4. Pick one small Go-heavy job in the GCP batch:
   - Update `GOPROXY` to point to AR go remote.
   - If repo is private, add the Go credential helper bootstrap.
   - Verify `go mod download` (and/or Bazel external fetch) is stable.
5. Roll out GOPROXY changes to the rest of the GCP job group.
6. After stable, remove goproxy deployment in the GCP cluster (keep it in legacy clusters until they are fully migrated).
