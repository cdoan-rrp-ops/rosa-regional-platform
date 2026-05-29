#!/bin/bash
# Run e2e API tests from rosa-regional-platform-api against the provisioned environment.
#
# API URL resolution (first match wins):
#   1. BASE_URL env var            — set by local wrapper scripts (ephemeral-env.sh, int-env.sh)
#   2. CREDS_DIR/api_url file — Prow-mounted secret for the standing int environment
#   3. SHARED_DIR terraform output — written by ephemeral-provider during CI provisioning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_DIR="${CREDS_DIR:-/var/run/rosa-credentials}"

source "${SCRIPT_DIR}/setup-aws-profiles.sh"

if [[ -n "${BASE_URL:-}" ]]; then
  echo "Using BASE_URL from environment: ${BASE_URL}"
else
  if [[ -r "${CREDS_DIR}/api_url" ]]; then
    echo "Using API URL from ${CREDS_DIR}/api_url (CI pre-existing environment)"
    BASE_URL="$(cat "${CREDS_DIR}/api_url")"
  else
    echo "No ${CREDS_DIR}/api_url found, falling back to terraform outputs (ephemeral environment)"
    TF_OUTPUTS="${SHARED_DIR}/regional-terraform-outputs.json"
    if [[ ! -r "${TF_OUTPUTS}" ]]; then
      echo "ERROR: ${TF_OUTPUTS} does not exist or is not readable" >&2
      exit 1
    fi
    BASE_URL="$(jq -r '.api_gateway_invoke_url.value // empty' "${TF_OUTPUTS}")"
    if [[ -z "${BASE_URL}" ]]; then
      echo "ERROR: api_gateway_invoke_url.value not found in ${TF_OUTPUTS}" >&2
      exit 1
    fi
  fi
fi
export BASE_URL
echo "Running API e2e tests against ${BASE_URL}"

# RHOBS API URL for observability E2E tests (Thanos Query read path).
# The query path is always available — uses the same invoke URL as remote-write.
if [[ -z "${RHOBS_API_URL:-}" ]]; then
  if [[ -r "${CREDS_DIR}/rhobs_api_url" ]]; then
    RHOBS_API_URL="$(cat "${CREDS_DIR}/rhobs_api_url")"
  elif [[ -n "${TF_OUTPUTS:-}" && -r "${TF_OUTPUTS:-}" ]]; then
    RHOBS_API_URL="$(jq -r '.rhobs_api_url.value // empty' "${TF_OUTPUTS}")"
  fi
fi
if [[ -n "${RHOBS_API_URL:-}" ]]; then
  export RHOBS_API_URL
  echo "RHOBS API URL: ${RHOBS_API_URL}"
else
  echo "WARNING: RHOBS_API_URL not available — observability tests will be skipped"
fi

# Use the regional account profile for authenticated API calls
export AWS_PROFILE="rrp-rc"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_REF="${E2E_REF:-main}"
E2E_REPO="${E2E_REPO:-https://github.com/openshift-online/rosa-regional-platform-api.git}"
CLI_REF="${CLI_REF:-main}"
CLI_REPO="${CLI_REPO:-https://github.com/openshift-online/rosa-regional-platform-cli.git}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
git clone --depth 1 --branch "${E2E_REF}" \
  "${E2E_REPO}" "${WORK_DIR}/api"
cd "${WORK_DIR}/api"

go install github.com/onsi/ginkgo/v2/ginkgo@v2.28.1
export PATH="$(go env GOPATH)/bin:${PATH}"

rc=0
make test-e2e || rc=$?

# Get regional account ID for CLI tests
if [[ -z "${E2E_ACCOUNT_ID:-}" ]]; then
  export E2E_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  echo "Regional account ID: ${E2E_ACCOUNT_ID}"
fi 

# --- HCP Creation E2E Tests ---
# Customer credentials come from the rrp-customer AWS profile.
# Only run if the platform API tests passed.
_have_customer_creds=false
if [[ $rc -ne 0 ]]; then
  echo "Skipping HCP creation tests — platform API tests failed (exit code: $rc)"
elif aws configure export-credentials --profile rrp-customer --format process &>/dev/null; then
  _cust_creds=$(aws configure export-credentials --profile rrp-customer --format process)
  export CUSTOMER_AWS_ACCESS_KEY_ID=$(echo "$_cust_creds" | jq -r '.AccessKeyId')
  export CUSTOMER_AWS_SECRET_ACCESS_KEY=$(echo "$_cust_creds" | jq -r '.SecretAccessKey')
  _cust_st=$(echo "$_cust_creds" | jq -r '.SessionToken // empty')
  [[ -n "$_cust_st" ]] && export CUSTOMER_AWS_SESSION_TOKEN="$_cust_st"
  unset _cust_creds _cust_st
  echo "Customer credentials loaded from rrp-customer profile"

  if [[ -z "${E2E_CUSTOMER_ACCOUNT_ID:-}" ]]; then
    export E2E_CUSTOMER_ACCOUNT_ID="$(aws sts get-caller-identity --profile rrp-customer --query Account --output text)"
    echo "Customer account ID: ${E2E_CUSTOMER_ACCOUNT_ID:0:8}..."
  fi
  _have_customer_creds=true
else
  echo "WARNING: No rrp-customer profile available — skipping HCP creation tests"
fi

if [[ "$_have_customer_creds" == "true" ]]; then
  test_hcp_creation() {
    echo ""
    echo "=== HCP Creation Tests ==="

    local HCP_CLUSTER_NAME="e2e-$(date +%s)"

    CLI_WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${CLI_WORK_DIR}"; rm -rf "${WORK_DIR}"' EXIT
    cd "${CLI_WORK_DIR}"
    git clone --depth 1 --branch "${CLI_REF}" \
      "${CLI_REPO}" "${CLI_WORK_DIR}/cli"
    cd "${CLI_WORK_DIR}/cli"

    export GOTOOLCHAIN=auto
    make build
    chmod 755 ./bin/rosactl

    export ROSACTL_BIN="${CLI_WORK_DIR}/cli/bin/rosactl"

    cd "${WORK_DIR}/api"

    "${ROSACTL_BIN}" login --url "${BASE_URL}"
    echo "Creating HCP cluster: ${HCP_CLUSTER_NAME}"

    export GINKGO_NO_COLOR=TRUE
    make test-e2e-cli || return $?

    echo "HCP creation test completed for: ${HCP_CLUSTER_NAME}"
  }

  test_hcp_creation || rc=$?
fi

if [[ $rc -ne 0 ]]; then
    echo ""
    echo "E2E tests failed (exit code: $rc). Collecting cluster logs..."

    # Pre-existing environment (integration): bare cluster names (regional, mc01)
    # Ephemeral environment: ci_prefix-based names derived from BUILD_ID
    if [[ -r "${CREDS_DIR}/api_url" ]]; then
        export CLUSTER_PREFIX=""
    elif [[ -n "${BUILD_ID:-}" ]]; then
        hash="$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-6)" \
            || { echo "WARNING: sha256sum failed — skipping log collection"; hash=""; }
        if [[ -n "$hash" ]]; then
            export CLUSTER_PREFIX="eph-${hash}-"
        fi
    else
        echo "WARNING: BUILD_ID not set — skipping log collection"
    fi

    if [[ -n "${CLUSTER_PREFIX+set}" ]]; then
        # Logs are left in S3 rather than added to public CI artifacts because
        # they may contain sensitive data (e.g. maestro secrets) that cannot be
        # reliably redacted. The S3 URIs are printed below for manual retrieval.
        S3_ONLY=true \
            "${REPO_ROOT}/scripts/dev/collect-cluster-logs.sh" || true

        # When HCP creation tests were attempted, also collect must-gather
        # resources from the MC (HostedCluster, NodePool, HyperShift operator
        # logs, Maestro agent) to help diagnose HCP creation failures.
        if [[ "${_have_customer_creds:-false}" == "true" ]]; then
            echo ""
            echo "Collecting HCP must-gather from Management Cluster(s)..."
            S3_ONLY=true \
                "${REPO_ROOT}/scripts/dev/collect-hcp-must-gather.sh" || true
        fi
    fi
    exit $rc
fi
