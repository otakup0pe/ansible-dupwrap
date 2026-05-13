#!/usr/bin/env bash
# End-to-end S3 test runner for dupwrap.
# Provisions opentofu infrastructure, runs molecule, tears down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/tofu"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
DISTRO="${MOLECULE_DISTRO:-ubuntu2404}"
TOFU_IMAGE="ghcr.io/opentofu/opentofu:1.9"

log() { echo "==> $1" >&2; }

tofu() {
    docker run --rm \
        -v "${TF_DIR}:/work" \
        -w /work \
        -e AWS_ACCESS_KEY_ID \
        -e AWS_SECRET_ACCESS_KEY \
        -e AWS_SESSION_TOKEN \
        -e AWS_REGION \
        "${TOFU_IMAGE}" \
        "$@"
}

cleanup() {
    log "Tearing down opentofu infrastructure..."
    tofu destroy -auto-approve -input=false 2>&1 | tail -5
    rm -f "${TF_DIR}/terraform.tfstate"*
    log "Cleanup complete."
}

# Always cleanup on exit
trap cleanup EXIT

# Step 0: Wait for vault-issued AWS creds to propagate
log "Waiting for vault-issued AWS credentials to propagate (up to 30s)..."
DEADLINE=$(($(date +%s) + 30))
while true; do
    if aws sts get-caller-identity --region us-west-2 >/dev/null 2>&1; then
        log "Vault credentials active."
        break
    fi
    if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
        log "ERROR: Vault-issued AWS credentials did not propagate within 30s"
        exit 1
    fi
    sleep 3
done

# Step 1: Provision S3 bucket and IAM user
log "Provisioning S3 test infrastructure..."
tofu init -input=false -no-color
tofu apply -auto-approve -input=false -no-color

# Step 2: Extract outputs
BUCKET_URI="$(tofu output -raw bucket_uri)"
AWS_KEY="$(tofu output -raw aws_access_key_id)"
AWS_SECRET="$(tofu output -raw aws_secret_access_key)"

log "Test bucket: ${BUCKET_URI}"
log "IAM user key: ${AWS_KEY}"

# Step 3: Wait for IAM credential propagation
log "Waiting for IAM credential propagation (up to 30s)..."
DEADLINE=$(($(date +%s) + 30))
while true; do
    if AWS_ACCESS_KEY_ID="${AWS_KEY}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET}" \
       aws sts get-caller-identity --region us-west-2 >/dev/null 2>&1; then
        log "IAM credentials active."
        break
    fi
    if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
        log "ERROR: IAM credentials did not propagate within 30s"
        exit 1
    fi
    sleep 3
done

# Step 4: Run molecule
log "Running molecule e2e-s3 scenario..."
cd "${REPO_DIR}"
DUPWRAP_E2E_BUCKET_URI="${BUCKET_URI}" \
DUPWRAP_E2E_AWS_ACCESS_KEY_ID="${AWS_KEY}" \
DUPWRAP_E2E_AWS_SECRET_ACCESS_KEY="${AWS_SECRET}" \
MOLECULE_DISTRO="${DISTRO}" \
    .venv/bin/molecule test -s e2e-s3

log "S3 e2e tests passed!"
# opentofu cleanup happens via trap
