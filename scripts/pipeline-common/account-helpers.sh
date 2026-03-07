#!/usr/bin/env bash
#
# account-helpers.sh - Credential switching helpers for multi-account pipelines
#
# Provides functions to switch between AWS accounts by assuming
# OrganizationAccountAccessRole from saved central (CodeBuild) credentials.
# Each use_* function always assumes from the central base credentials,
# never from a previously-assumed role, so you can freely switch accounts.
#
# Usage:
#   source scripts/pipeline-common/account-helpers.sh
#   init_account_helpers
#
#   use_rc_account
#   # ... do RC operations ...
#
#   use_mc_account
#   # ... do MC operations ...
#
# Expected environment variables:
#   TARGET_ACCOUNT_ID         - MC account ID (for use_mc_account)
#   REGIONAL_AWS_ACCOUNT_ID   - RC account ID (for use_rc_account), supports ssm:/ prefix
#   TARGET_REGION             - Target AWS region (for SSM resolution)
#   TARGET_ALIAS              - Cluster alias (for session naming)

set -euo pipefail

# Internal storage for central credentials (not exported)
_CENTRAL_AWS_ACCESS_KEY_ID=""
_CENTRAL_AWS_SECRET_ACCESS_KEY=""
_CENTRAL_AWS_SESSION_TOKEN=""

# Resolved RC account ID (cached after first resolution)
_RESOLVED_RC_ACCOUNT_ID=""

# =============================================================================
# init_account_helpers - Capture CodeBuild's ambient credentials
# =============================================================================
# Call once at the start of a buildspec. Saves the current (central account)
# credentials so that use_* functions can always assume from them.
init_account_helpers() {
    _CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    _CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    _CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

    export CENTRAL_ACCOUNT_ID
    CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    echo "Account helpers initialized"
    echo "  Central Account: $CENTRAL_ACCOUNT_ID"
    echo ""
}

# =============================================================================
# use_mc_account - Switch to Management Cluster account
# =============================================================================
# Assumes OrganizationAccountAccessRole in TARGET_ACCOUNT_ID using central creds.
# If TARGET_ACCOUNT_ID == CENTRAL_ACCOUNT_ID, restores central creds directly.
use_mc_account() {
    _assume_account "${TARGET_ACCOUNT_ID}" "mc-${TARGET_ALIAS:-pipeline}"
}

# =============================================================================
# use_rc_account - Switch to Regional Cluster account
# =============================================================================
# Assumes OrganizationAccountAccessRole in REGIONAL_AWS_ACCOUNT_ID using central creds.
# Resolves SSM parameter references (ssm:/path) on first call and caches the result.
use_rc_account() {
    # Resolve REGIONAL_AWS_ACCOUNT_ID if it's an SSM reference
    if [ -z "$_RESOLVED_RC_ACCOUNT_ID" ]; then
        _RESOLVED_RC_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"

        if [[ "$_RESOLVED_RC_ACCOUNT_ID" =~ ^ssm:/ ]]; then
            local ssm_param="${_RESOLVED_RC_ACCOUNT_ID#ssm:}"
            echo "Resolving SSM parameter: $ssm_param"

            # Use central creds to resolve SSM (parameter is in central or target account)
            _RESOLVED_RC_ACCOUNT_ID=$(
                AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID" \
                AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY" \
                AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN" \
                aws ssm get-parameter \
                    --name "$ssm_param" \
                    --with-decryption \
                    --query 'Parameter.Value' \
                    --output text \
                    --region "${TARGET_REGION}")

            echo "Resolved RC account: $_RESOLVED_RC_ACCOUNT_ID"
        fi
    fi

    _assume_account "$_RESOLVED_RC_ACCOUNT_ID" "rc-${TARGET_ALIAS:-pipeline}"
}

# =============================================================================
# use_central_account - Restore central account credentials
# =============================================================================
use_central_account() {
    export AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN"
    echo "Switched to central account: $CENTRAL_ACCOUNT_ID"
}

# =============================================================================
# get_rc_account_id - Return the resolved RC account ID
# =============================================================================
get_rc_account_id() {
    if [ -z "$_RESOLVED_RC_ACCOUNT_ID" ]; then
        # Force resolution by calling use_rc_account logic
        _RESOLVED_RC_ACCOUNT_ID="${REGIONAL_AWS_ACCOUNT_ID}"
        if [[ "$_RESOLVED_RC_ACCOUNT_ID" =~ ^ssm:/ ]]; then
            local ssm_param="${_RESOLVED_RC_ACCOUNT_ID#ssm:}"
            _RESOLVED_RC_ACCOUNT_ID=$(
                AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID" \
                AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY" \
                AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN" \
                aws ssm get-parameter \
                    --name "$ssm_param" \
                    --with-decryption \
                    --query 'Parameter.Value' \
                    --output text \
                    --region "${TARGET_REGION}")
        fi
    fi
    echo "$_RESOLVED_RC_ACCOUNT_ID"
}

# =============================================================================
# Internal: _assume_account - Assume role in the specified account
# =============================================================================
_assume_account() {
    local account_id="$1"
    local session_name="$2"

    if [ "$account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        echo "Target account ($account_id) is central account - using central credentials"
        use_central_account
        return
    fi

    local role_arn="arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole"

    local creds
    if ! creds=$(
        AWS_ACCESS_KEY_ID="$_CENTRAL_AWS_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$_CENTRAL_AWS_SECRET_ACCESS_KEY" \
        AWS_SESSION_TOKEN="$_CENTRAL_AWS_SESSION_TOKEN" \
        aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "$session_name" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
        echo "ERROR: Failed to assume role $role_arn"
        echo "Error: $creds"
        return 1
    fi

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}')
    AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}')
    AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}')

    local assumed_account
    assumed_account=$(aws sts get-caller-identity --query Account --output text)

    if [ "$assumed_account" != "$account_id" ]; then
        echo "ERROR: Assumed wrong account. Expected $account_id, got $assumed_account"
        return 1
    fi

    echo "Switched to account: $assumed_account"
}
