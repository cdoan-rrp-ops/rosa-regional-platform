#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

## ===============================
## Configuration
## ===============================

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""

# Terraform variables (only values that differ from terraform defaults)
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_app_code="e2e"
export TF_VAR_service_phase="test"
export TF_VAR_cost_center="000"
export TF_VAR_repository_url="${REPOSITORY_URL:-https://github.com/openshift-online/rosa-regional-platform.git}"
export TF_VAR_repository_branch="${REPOSITORY_BRANCH:-main}"
echo "Targeting repository: ${TF_VAR_repository_url} branch: ${TF_VAR_repository_branch}"

# Platform Container images
# TODO: codepipeline will be able to build the platform for each or use public image
RC_CONTAINER_IMAGE="633630779107.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-01c48e:3278a75292a3"
MC_CONTAINER_IMAGE="018092638725.dkr.ecr.us-east-1.amazonaws.com/e2e-platform-7f0b54:3278a75292a3"

# ArgoCD environment
export ENVIRONMENT="e2e"
export REGION_DEPLOYMENT="us-east-1" # Note - this is not necesarily equal to the AWS_REGION! Could be `us-east-1-v2`

# Paths
MC_TFVARS="${REPO_ROOT}/terraform/config/management-cluster/terraform.tfvars"

# Credentials mounted at /var/run/rosa-credentials/ via ci-operator credentials mount
CREDS_DIR="/var/run/rosa-credentials/"

## ===============================
## Helper Functions
## ===============================

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] e2e:$*"; }
log_info() { log " $1"; }
log_success() { log " $1"; }
log_error() { log " $1" >&2; }
log_phase() {
    echo ""
    echo "=========================================="
    log "$1"
    echo "=========================================="
}

compute_hash() {
    echo "$1" | sha256sum | cut -c1-6
}

configure_state() {
    local hash="$1"
    local resource="$2"
    export TF_STATE_BUCKET="e2e-rosa-regional-platform-${hash}"
    export TF_STATE_KEY="e2e-rosa-regional-platform-${resource}-${hash}.tfstate"
    export TF_STATE_REGION=${AWS_REGION}
}

terraform_init() {
    local tf_dir="$1"
    local use_lockfile="${2:-true}"
    cd "${REPO_ROOT}/${tf_dir}"
    terraform init -reconfigure \
        -backend-config="bucket=${TF_STATE_BUCKET}" \
        -backend-config="key=${TF_STATE_KEY}" \
        -backend-config="region=${TF_STATE_REGION}" \
        -backend-config="use_lockfile=${use_lockfile}"
}

# TODO: Eliminate this tfvars file by setting cluster_id, enable_bastion, and
# regional_aws_account_id as TF_VAR_ exports, and updating the IoT scripts to
# accept values via env vars instead of parsing a tfvars path.
write_mc_tfvars() {
    log_info "Writing management cluster terraform.tfvars..."
    cat > "${MC_TFVARS}" <<EOF
cluster_id = "mc-${MC_HASH}"
app_code = "e2e"
service_phase = "test"
cost_center = "000"
repository_url = "${TF_VAR_repository_url}"
repository_branch = "${TF_VAR_repository_branch}"
enable_bastion = false
region = "${AWS_REGION}"
regional_aws_account_id = "${REGIONAL_ACCOUNT_ID}"
EOF
}

source "$REPO_ROOT/ci/utils.sh"

## ===============================
## Credential Setup
## ===============================

## Setup AWS Account 0 (regional)

REGIONAL_CREDS=$(mktemp)
cat > "${REGIONAL_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/regional_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/regional_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
aws sts get-caller-identity

REGIONAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using REGIONAL_ACCOUNT_ID: ${REGIONAL_ACCOUNT_ID}"

## Setup AWS Account 1 (management)

MGMT_CREDS=$(mktemp)
cat > "${MGMT_CREDS}" <<EOF
[default]
aws_access_key_id = $(cat "${CREDS_DIR}/management_access_key")
aws_secret_access_key = $(cat "${CREDS_DIR}/management_secret_key")
EOF

export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
aws sts get-caller-identity

MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Using MANAGEMENT_ACCOUNT_ID: ${MANAGEMENT_ACCOUNT_ID}"

# Compute hashes (BUILD_ID from prow job; fall back to account ID for local runs)
# Hashes are used for unique resources to allow parallel tests in the same AWS accounts.
RC_HASH=$(compute_hash "${BUILD_ID:-${REGIONAL_ACCOUNT_ID}}")
MC_HASH=$(compute_hash "${BUILD_ID:-${MANAGEMENT_ACCOUNT_ID}}")

## ===============================
## Parse Arguments
## ===============================

TEARDOWN=false
for arg in "$@"; do
  case "$arg" in
    --teardown) TEARDOWN=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--teardown]" >&2
      exit 1
      ;;
  esac
done

## ===============================
## Teardown Mode
## ===============================

if [ "${TEARDOWN}" = true ]; then
  log_phase "Teardown"

  # Destroy Management Cluster (management account, reverse of Step 4)
  log_phase "Destroying Management Cluster"
  export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
  export HASH="${MC_HASH}"
  configure_state "${MC_HASH}" "mc"
  export TF_VAR_container_image="${MC_CONTAINER_IMAGE}"
  export TF_VAR_target_alias="e2e-rc-${MC_HASH}"
  export TF_VAR_cluster_id="management-${MC_HASH}"
  export CLUSTER_TYPE="management-cluster"
  write_mc_tfvars

  # Read IoT cert/config from RC state (terraform destroy needs these vars).
  # If state is missing (e.g. provisioning failed), create dummy files so
  # terraform destroy can still proceed — the content doesn't matter for destroy.
  _SAVED_CREDS="${AWS_SHARED_CREDENTIALS_FILE}"
  export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
  if ! source "$REPO_ROOT/scripts/read-iot-state.sh" "$REGIONAL_ACCOUNT_ID" "mc-${MC_HASH}" "$AWS_REGION"; then
    log_info "IoT state not found, creating dummy files for terraform destroy"
    export TF_VAR_maestro_agent_cert_file=$(mktemp /tmp/agent-cert-XXXXXX.json)
    export TF_VAR_maestro_agent_config_file=$(mktemp /tmp/agent-config-XXXXXX.json)
    echo '{}' > "$TF_VAR_maestro_agent_cert_file"
    echo '{}' > "$TF_VAR_maestro_agent_config_file"
  fi
  export AWS_SHARED_CREDENTIALS_FILE="${_SAVED_CREDS}"
  export TF_VAR_regional_aws_account_id="$REGIONAL_ACCOUNT_ID"

  create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
  terraform_init "terraform/config/management-cluster" "false"
  terraform destroy -auto-approve || { log_error "MC destruction failed"; exit 1; }
  cd "$REPO_ROOT"
  rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"
  log_success "Management Cluster destroyed"

  # Cleanup IoT resources via terraform destroy (regional account, reverse of Step 2)
  log_phase "Destroying IoT resources"
  export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
  export HASH="${RC_HASH}"
  configure_state "${RC_HASH}" "iot"
  export TF_VAR_container_image="${RC_CONTAINER_IMAGE}"
  export TF_VAR_target_alias="e2e-rc-${RC_HASH}"

  export AUTO_APPROVE=true
  "$REPO_ROOT/scripts/cleanup-maestro-agent-iot.sh" "${MC_TFVARS}" \
      || { log_error "Failed to cleanup IoT resources"; exit 1; }
  log_success "IoT resources cleaned up"

  # Destroy Regional Cluster (regional account, reverse of Step 1)
  log_phase "Destroying Regional Cluster"
  export CLUSTER_TYPE="regional-cluster"
  configure_state "${RC_HASH}" "rc"
  create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
  terraform_init "terraform/config/regional-cluster" "true"
  terraform destroy -auto-approve || { log_error "RC destruction failed"; exit 1; }
  cd "$REPO_ROOT"
  log_success "Regional Cluster destroyed"

  log_phase "Teardown complete"
  exit 0
fi

## ===============================
## Provisioning
## ===============================

## ---- Step 1: RC Provisioning (regional account) ----

log_phase "Step 1: Regional Cluster Provisioning"
export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"
export HASH="${RC_HASH}"
configure_state "${RC_HASH}" "rc"
export TF_VAR_container_image="${RC_CONTAINER_IMAGE}"
export TF_VAR_target_alias="e2e-rc-${RC_HASH}"
export CLUSTER_TYPE="regional-cluster"
# Allow regional account to access the API
export TF_VAR_bootstrap_accounts='["${REGIONAL_ACCOUNT_ID}"]'

create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }
log_info "Container image: ${TF_VAR_container_image}"
"$REPO_ROOT/scripts/dev/validate-argocd-config.sh" regional-cluster
terraform_init "terraform/config/regional-cluster" "true"
terraform apply -auto-approve
API_URL=$(terraform output -raw api_test_command | grep -oE 'https://[^/]+')
echo "API URL: ${API_URL}"

cd "$REPO_ROOT"
"$REPO_ROOT/scripts/bootstrap-argocd.sh" regional-cluster \
    || { log_error "RC ArgoCD bootstrap failed"; exit 1; }
log_success "Regional Cluster provisioned"

## ---- Step 2: IoT Regional (regional account) ----

log_phase "Step 2: IoT Regional Provisioning"
"$REPO_ROOT/scripts/bootstrap-state.sh" "${AWS_REGION}" \
    || { log_error "Failed to bootstrap RC state bucket"; exit 1; }
write_mc_tfvars
configure_state "${RC_HASH}" "iot-rc"
export AUTO_APPROVE=true
export IOT_STATE_BUCKET="terraform-state-${REGIONAL_ACCOUNT_ID}"
"$REPO_ROOT/scripts/provision-maestro-agent-iot-regional.sh" "${MC_TFVARS}" \
    || { log_error "IoT regional provisioning failed"; exit 1; }
log_success "IoT regional resources provisioned"

## ---- Step 3: Read IoT state and provision MC (management account) ----

log_phase "Step 3: Read IoT State from RC"
# Read IoT cert/config from RC state while still on regional creds
source "$REPO_ROOT/scripts/read-iot-state.sh" "$REGIONAL_ACCOUNT_ID" "mc-${MC_HASH}" "$AWS_REGION"

## ---- Step 4: MC Provisioning (management account) ----

log_phase "Step 4: Management Cluster Provisioning"
export AWS_SHARED_CREDENTIALS_FILE="${MGMT_CREDS}"
export HASH="${MC_HASH}"
configure_state "${MC_HASH}" "mc"
export TF_VAR_container_image="${MC_CONTAINER_IMAGE}"
export TF_VAR_target_alias="e2e-rc-${MC_HASH}"
export TF_VAR_cluster_id="management-${MC_HASH}"
export TF_VAR_regional_aws_account_id="$REGIONAL_ACCOUNT_ID"
export CLUSTER_TYPE="management-cluster"

create_s3_bucket || { log_error "Failed to setup S3 backend"; exit 1; }

"$REPO_ROOT/scripts/dev/validate-argocd-config.sh" management-cluster

terraform_init "terraform/config/management-cluster" "false"
terraform apply -auto-approve
cd "$REPO_ROOT"

# Clean up temp cert files
rm -f "${TF_VAR_maestro_agent_cert_file:-}" "${TF_VAR_maestro_agent_config_file:-}"

"$REPO_ROOT/scripts/bootstrap-argocd.sh" management-cluster \
    || { log_error "MC ArgoCD bootstrap failed"; exit 1; }
log_success "Management Cluster provisioned"

sleep 60

## ===============================
## Validation
## ===============================

## ---- Platform API Test (regional account) ----

log_phase "Platform API Test"

export AWS_SHARED_CREDENTIALS_FILE="${REGIONAL_CREDS}"

"$REPO_ROOT/ci/e2e-platform-api-test.sh" "${API_URL}" "mc-${MC_HASH}"

log_success "Platform API tests passed"
