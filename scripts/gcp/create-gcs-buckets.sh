#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/gcp/create-gcs-buckets.sh \
    --project <PROJECT_ID> \
    --location <LOCATION> \
    --remote-cache-bucket <BUCKET_NAME>

Notes:
- Bucket names are globally unique.
- This script creates buckets with UBLA + Public Access Prevention enabled.
- It also enforces: versioning disabled and soft delete disabled.
EOF
}

PROJECT_ID=""
LOCATION=""
REMOTE_CACHE_BUCKET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"; shift 2;;
    --location)
      LOCATION="${2:-}"; shift 2;;
    --remote-cache-bucket)
      REMOTE_CACHE_BUCKET="${2:-}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2;;
  esac
done

if [[ -z "${PROJECT_ID}" || -z "${LOCATION}" || -z "${REMOTE_CACHE_BUCKET}" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

# Avoid writing to a non-writable default gcloud config dir in restricted environments.
export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/tmp/gcloud}"

bucket_exists() {
  local b="$1"
  gcloud storage buckets describe "gs://${b}" --project="${PROJECT_ID}" >/dev/null 2>&1
}

create_bucket_if_missing() {
  local b="$1"
  if bucket_exists "${b}"; then
    echo "[SKIP] Bucket exists: gs://${b}"
    return 0
  fi

echo "[CREATE] gs://${b} (project=${PROJECT_ID}, location=${LOCATION})"
  gcloud storage buckets create "gs://${b}" \
    --project="${PROJECT_ID}" \
    --location="${LOCATION}" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention
}

ensure_bucket_baseline_config() {
  local b="$1"
  echo "[CONFIG] Enforce baseline (UBLA/PAP, no versioning, no soft delete): gs://${b}"
  gcloud storage buckets update "gs://${b}" \
    --project="${PROJECT_ID}" \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --no-versioning \
    --clear-soft-delete
}

create_bucket_if_missing "${REMOTE_CACHE_BUCKET}"
ensure_bucket_baseline_config "${REMOTE_CACHE_BUCKET}"

echo ""
echo "Next steps (not done by this script):"
echo "- Grant IAM on buckets to the CI Google Service Account (GSA)."
echo "- Bind Kubernetes ServiceAccount (KSA) to that GSA via Workload Identity."
