# GCS Bucket Runbook (Bazel Remote Cache)

Overview
- This repo does not provision GCS buckets via IaC today (Terraform/Crossplane/Config Connector are not in place).
- We keep the bucket creation and baseline configuration as a runbook + scripts for repeatability and reviewability.

Bucket
- Bazel remote cache bucket (AC/CAS)
  - Purpose: Store Bazel remote cache objects (action cache + CAS blobs).
  - Access: CI pods need read/write.
  - Data: Cache only (eviction impacts performance only, not correctness).

Naming and location
- Bucket names are global and must be unique.
- Prefer a regional bucket in the same region as your GKE cluster to minimize latency and egress cost.
- Storage class: `STANDARD` for remote cache (hot objects).

Security baseline (recommended)
- Enable Uniform Bucket-Level Access (UBLA).
- Enforce Public Access Prevention (PAP).
- Use bucket-level IAM (no object ACLs).
- Keep Object Versioning disabled.
- Keep Soft Delete disabled.

All steps below can be done via CLI/API. There is no "must click in Console" configuration for these bucket settings.

Prereqs
- `gcloud` installed
- Permissions to create buckets and manage IAM in the target GCP project.
- If your local gcloud config dir is not writable, set:
  - `export CLOUDSDK_CONFIG=/tmp/gcloud`

Create buckets (CLI)
```bash
export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/tmp/gcloud}"

export PROJECT_ID="<your-gcp-project-id>"
export LOCATION="<gcp-region>" # e.g. us-central1

export BAZEL_REMOTE_CACHE_BUCKET="<globally-unique-bucket-name>"

# Login if needed
gcloud auth login

# Create Bazel remote cache bucket
gcloud storage buckets create "gs://${BAZEL_REMOTE_CACHE_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access \
  --public-access-prevention
```

Versioning / Soft delete
- Remote cache is ephemeral and can be regenerated. Turning on versioning/soft delete usually just increases storage cost and makes deletions/eviction less effective.
- Recommended defaults for a remote cache bucket:
  - `versioning`: disabled
  - `soft delete`: disabled

Enforce these settings via CLI:
```bash
gcloud storage buckets update "gs://${BAZEL_REMOTE_CACHE_BUCKET}" \
  --project="${PROJECT_ID}" \
  --no-versioning \
  --clear-soft-delete
```

Lifecycle (cost control)
- GCS lifecycle rules do not support "delete if not accessed in N days".
- To avoid accidental cache churn, this runbook does not set any lifecycle policy by default.
- If you need size/LRU-like eviction semantics, use a remote cache server that supports eviction (e.g. bazel-remote/buildbarn) instead of relying on raw GCS bucket lifecycle.

IAM (Workload Identity recommended)
Create a Google Service Account (GSA) and grant it bucket permissions:
```bash
export GSA_NAME="bazel-remote-cache"
gcloud iam service-accounts create "${GSA_NAME}" --project="${PROJECT_ID}"
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Remote cache needs R/W on objects.
gcloud storage buckets add-iam-policy-binding "gs://${BAZEL_REMOTE_CACHE_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# Optional but practical: allow clients/tools to read bucket metadata (storage.buckets.get).
# Some tooling (e.g. gsutil "ls -b") requires this.
gcloud storage buckets add-iam-policy-binding "gs://${BAZEL_REMOTE_CACHE_BUCKET}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/storage.legacyBucketReader"
```

Bind KSA -> GSA (example for tidb jobs using default KSA)
```bash
export KSA_NAMESPACE="jenkins-tidb"
export KSA_NAME="default"

# Allow KSA to impersonate the GSA via Workload Identity.
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${KSA_NAMESPACE}/${KSA_NAME}]"

# Annotate the KSA to use the GSA.
kubectl -n "${KSA_NAMESPACE}" annotate serviceaccount "${KSA_NAME}" \
  iam.gke.io/gcp-service-account="${GSA_EMAIL}" --overwrite
```

Validation
```bash
gcloud storage buckets describe "gs://${BAZEL_REMOTE_CACHE_BUCKET}" --format=yaml

# Check these keys in the output:
# - location
# - iamConfiguration.uniformBucketLevelAccess.enabled
# - iamConfiguration.publicAccessPrevention
# - versioning.enabled
# - softDeletePolicy (or absence if not enabled)
```

Notes / follow-ups
- Blast radius: mapping `jenkins-tidb/default` gives all pods in that namespace the same GSA. For tighter security, create a dedicated KSA and reference it explicitly from pod templates.
- Consider separate buckets for different trust boundaries (e.g. PR vs post-merge) if cache poisoning is a concern.
