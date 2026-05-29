#!/bin/bash
# Collect HCP must-gather kube resources from Management Cluster(s).
#
# Uploads a must-gather shell script to a temporary S3 location, then runs it
# via the log-collector ECS task on each MC. The script collects Kubernetes
# resources needed to debug HCP creation E2E failures:
#
#   - hypershift namespace: operator pods/logs/events, Deployment definitions
#   - clusters-* namespaces: HostedCluster, NodePool, control-plane pod logs/events
#   - maestro-agent namespace: agent pods/logs/events
#   - Cluster-scoped: all HostedClusters, NodePools, node status
#
# This script is the authoritative implementation used by both local dev CLI
# (ephemeral-env.sh, int-env.sh) and CI (ci/e2e-tests.sh).
#
# Callers set CLUSTER_PREFIX to control cluster name resolution:
#   - Ephemeral: CLUSTER_PREFIX="eph-a1b2c3-" → eph-a1b2c3-mc01
#   - Integration: CLUSTER_PREFIX=""           → mc01
#
# MC clusters are discovered dynamically by listing ECS clusters matching
# ${CLUSTER_PREFIX}mc*-bastion, so mc01, mc02, etc. are all collected.
#
# Usage:
#   collect-hcp-must-gather.sh
#
# Required environment variables:
#   CLUSTER_PREFIX  — Cluster name prefix (e.g. "eph-a1b2c3-" or "" for bare names)
#   AWS_CONFIG_FILE — Path to AWS config with rrp-rc and rrp-mc profiles
#
# Optional:
#   LOG_OUTPUT_DIR    — Output directory (default: /tmp/<prefix>hcp-must-gather-<timestamp>)
#   S3_ONLY           — If "true", leave archives in S3 and print URIs (used in CI to
#                       avoid publishing sensitive data to public artifacts)
#   HCP_CLUSTER_NAME  — Limit must-gather to the named HCP cluster (filters clusters-*
#                       namespaces and resource searches by name)
#
# All collection failures are logged but do not cause a non-zero exit.

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

redact_logs() {
    local dir="$1"
    find "$dir" -type f \( -name "*.yaml" -o -name "*.log" -o -name "*.txt" -o -name "*.json" \) | while read -r f; do
        [[ -s "$f" ]] || continue
        sed_inplace \
            -e 's/\(AKIA\|ASIA\)[A-Z0-9]\{16\}/[REDACTED_AWS_KEY]/g' \
            -e 's/\(aws_secret_access_key\|secret_key\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/\(aws_session_token\|security_token\)\([ =:]*\)[^ ]*/\1\2[REDACTED]/gi' \
            -e 's/"\(aws_secret_access_key\|secret_key\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            -e 's/"\(aws_session_token\|security_token\)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1":"[REDACTED]"/gi' \
            "$f"
    done
}

# Ensure the log-collection S3 bucket exists.
ensure_logs_bucket() {
    local account_id="$1"
    local region="$2"
    local bucket="bastion-log-collection-${account_id}-${region}-an"

    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        return 0
    fi

    echo "  Creating log-collection bucket ${bucket}..."
    aws s3api create-bucket \
        --bucket "$bucket" \
        --bucket-namespace account-regional \
        --region "$region" > /dev/null

    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration \
            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true > /dev/null

    aws s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket" \
        --lifecycle-configuration '{"Rules":[{"ID":"expire-logs","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":7},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' > /dev/null
}

# Discover MC cluster IDs by listing ECS clusters matching ${prefix}mc*-bastion.
discover_mc_clusters() {
    local prefix="$1"
    aws ecs list-clusters --query 'clusterArns[*]' --output text 2>/dev/null \
        | tr '\t' '\n' \
        | grep -oE "[^/]+$" \
        | grep "^${prefix}mc.*-bastion$" \
        | sed 's/-bastion$//' \
        | sort
}

# ---------------------------------------------------------------------------
# The must-gather script that runs INSIDE the ECS log-collector container.
# This is uploaded to S3 so the container can download and execute it.
# ---------------------------------------------------------------------------
write_must_gather_script() {
    cat <<'MUST_GATHER_SCRIPT'
#!/bin/bash
# HCP Must-Gather — runs inside the log-collector ECS container.
# Called with: bash /tmp/hcp-must-gather.sh
# Environment: CLUSTER_NAME, AWS_REGION, S3_BUCKET, S3_KEY, HCP_CLUSTER_NAME (optional)

set -uo pipefail

DEST_DIR=/tmp/hcp-must-gather
mkdir -p "$DEST_DIR"

echo "=== HCP Must-Gather ==="
echo "Cluster:    $CLUSTER_NAME"
echo "S3 dest:    s3://$S3_BUCKET/$S3_KEY"
echo "HCP filter: ${HCP_CLUSTER_NAME:-<all>}"
echo ""

# Configure kubectl to talk to this EKS cluster
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# ---------------------------------------------------------------------------
# Helper: collect all pods + logs for a namespace
# ---------------------------------------------------------------------------
collect_namespace() {
    local ns="$1"
    local ns_dir="${DEST_DIR}/${ns}"
    mkdir -p "$ns_dir"

    echo "  Collecting namespace: $ns"

    # Events sorted by timestamp
    kubectl get events -n "$ns" --sort-by='.lastTimestamp' \
        > "${ns_dir}/events.txt" 2>&1 || true

    # Pod resource definitions
    kubectl get pods -n "$ns" -o yaml \
        > "${ns_dir}/pods.yaml" 2>&1 || true

    kubectl describe pods -n "$ns" \
        > "${ns_dir}/pods-describe.txt" 2>&1 || true

    # Per-container logs (current + previous restart if available)
    local pods
    pods=$(kubectl get pods -n "$ns" -o name 2>/dev/null || true)
    while IFS= read -r pod; do
        [[ -n "$pod" ]] || continue
        local pod_name="${pod#pod/}"
        local pod_dir="${ns_dir}/pods/${pod_name}"
        mkdir -p "$pod_dir"

        local containers
        containers=$(kubectl get "$pod" -n "$ns" \
            -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
        while IFS= read -r container; do
            [[ -n "$container" ]] || continue
            kubectl logs "$pod" -n "$ns" -c "$container" --tail=5000 \
                > "${pod_dir}/${container}.log" 2>&1 || true
            kubectl logs "$pod" -n "$ns" -c "$container" --previous --tail=5000 \
                > "${pod_dir}/${container}.previous.log" 2>&1 || true
            # Remove empty previous-log files to reduce noise
            [[ -s "${pod_dir}/${container}.previous.log" ]] \
                || rm -f "${pod_dir}/${container}.previous.log"
        done <<< "$containers"
    done <<< "$pods"
}

# ---------------------------------------------------------------------------
# 1. hypershift namespace — HyperShift operator health
# ---------------------------------------------------------------------------
echo "Collecting hypershift namespace..."
mkdir -p "${DEST_DIR}/hypershift"

kubectl get deployments -n hypershift -o yaml \
    > "${DEST_DIR}/hypershift/deployments.yaml" 2>&1 || true

kubectl get all -n hypershift -o wide \
    > "${DEST_DIR}/hypershift/all-resources.txt" 2>&1 || true

collect_namespace "hypershift"

# ---------------------------------------------------------------------------
# 2. clusters-* namespaces — HostedCluster, NodePool, control-plane pods
# ---------------------------------------------------------------------------
all_cluster_ns=$(kubectl get namespaces \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep '^clusters-' || true)

if [[ -n "${HCP_CLUSTER_NAME:-}" ]]; then
    all_cluster_ns=$(echo "$all_cluster_ns" | grep "${HCP_CLUSTER_NAME}" || true)
fi

if [[ -z "$all_cluster_ns" ]]; then
    echo "No clusters-* namespaces found (filter: ${HCP_CLUSTER_NAME:-<all>})"
else
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        ns_dir="${DEST_DIR}/${ns}"
        mkdir -p "$ns_dir"

        echo "Collecting $ns..."

        # HostedCluster — primary resource for HCP creation status
        kubectl get hostedcluster -n "$ns" -o yaml \
            > "${ns_dir}/hostedclusters.yaml" 2>&1 || true
        kubectl describe hostedcluster -n "$ns" \
            > "${ns_dir}/hostedclusters-describe.txt" 2>&1 || true

        # NodePool — worker node configuration
        kubectl get nodepools.hypershift.openshift.io -n "$ns" -o yaml \
            > "${ns_dir}/nodepools.yaml" 2>&1 || true
        kubectl describe nodepools.hypershift.openshift.io -n "$ns" \
            > "${ns_dir}/nodepools-describe.txt" 2>&1 || true

        # ConfigMaps (may contain installation config)
        kubectl get configmaps -n "$ns" -o yaml \
            > "${ns_dir}/configmaps.yaml" 2>&1 || true

        # Secrets — metadata only (never dump secret data)
        kubectl get secrets -n "$ns" \
            -o custom-columns='NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp' \
            > "${ns_dir}/secrets-metadata.txt" 2>&1 || true

        collect_namespace "$ns"
    done <<< "$all_cluster_ns"
fi

# ---------------------------------------------------------------------------
# 3. maestro-agent namespace — Maestro connectivity to RC
# ---------------------------------------------------------------------------
if kubectl get namespace maestro-agent &>/dev/null; then
    echo "Collecting maestro-agent namespace..."
    mkdir -p "${DEST_DIR}/maestro-agent"

    kubectl get deployments -n maestro-agent -o yaml \
        > "${DEST_DIR}/maestro-agent/deployments.yaml" 2>&1 || true

    collect_namespace "maestro-agent"
else
    echo "maestro-agent namespace not found — skipping"
fi

# ---------------------------------------------------------------------------
# 4. Cluster-scoped HCP resources (visible from any namespace)
# ---------------------------------------------------------------------------
echo "Collecting cluster-scoped HCP resources..."
mkdir -p "${DEST_DIR}/cluster-scoped"

kubectl get hostedclusters.hypershift.openshift.io --all-namespaces -o yaml \
    > "${DEST_DIR}/cluster-scoped/hostedclusters-all.yaml" 2>&1 || true

kubectl get nodepools.hypershift.openshift.io --all-namespaces -o yaml \
    > "${DEST_DIR}/cluster-scoped/nodepools-all.yaml" 2>&1 || true

kubectl get nodes -o wide \
    > "${DEST_DIR}/cluster-scoped/nodes.txt" 2>&1 || true

kubectl describe nodes \
    > "${DEST_DIR}/cluster-scoped/nodes-describe.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# Pack and upload to S3
# ---------------------------------------------------------------------------
echo ""
echo "Uploading must-gather to S3..."
tar czf /tmp/hcp-must-gather.tar.gz -C /tmp hcp-must-gather
aws s3 cp /tmp/hcp-must-gather.tar.gz "s3://$S3_BUCKET/$S3_KEY"
echo "Done."
MUST_GATHER_SCRIPT
}

# ---------------------------------------------------------------------------
# Run must-gather for one MC cluster
# ---------------------------------------------------------------------------
collect_must_gather_for_cluster() {
    local cluster_id="$1"
    local out_dir="$2"

    echo "==> Running HCP must-gather on ${cluster_id}..."

    local ecs_cluster="${cluster_id}-bastion"
    local task_def="${cluster_id}-log-collector"

    local account_id region
    account_id=$(aws sts get-caller-identity --query Account --output text) \
        || { echo "  Could not determine account ID"; return 1; }
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
    local s3_bucket="bastion-log-collection-${account_id}-${region}-an"

    ensure_logs_bucket "$account_id" "$region"

    local run_id
    run_id="$(date +%s%N)-$$-${RANDOM}"
    local s3_key="hcp-must-gather-${run_id}.tar.gz"
    local script_s3_key="hcp-must-gather-script-${run_id}.sh"

    # Upload the must-gather script to S3 so the container can download + exec it
    local tmp_script
    tmp_script="$(mktemp -t hcp-must-gather-XXXXXX.sh)"
    write_must_gather_script > "$tmp_script"
    aws s3 cp "$tmp_script" "s3://${s3_bucket}/${script_s3_key}" --quiet \
        || { echo "  Failed to upload must-gather script to S3"; rm -f "$tmp_script"; return 1; }
    rm -f "$tmp_script"

    # Discover network config from the bastion security group
    local sg_id subnets vpc_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${cluster_id}-bastion" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) \
        || { echo "  Could not find security group for ${cluster_id}"; return 1; }
    [[ "$sg_id" != "None" && -n "$sg_id" ]] \
        || { echo "  Security group '${cluster_id}-bastion' not found"; return 1; }

    vpc_id=$(aws ec2 describe-security-groups \
        --group-ids "$sg_id" \
        --query 'SecurityGroups[0].VpcId' --output text)

    subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
        --query 'Subnets[].SubnetId' --output text \
        | tr '\t' ',') \
        || { echo "  Could not find private subnets for ${cluster_id}"; return 1; }

    # Override the log-collector task command to download and run our script.
    # The task definition uses entryPoint=["/bin/bash","-c"], so we replace the
    # command argument (the script body) with a download-and-exec one-liner.
    local cmd
    cmd="aws s3 cp s3://${s3_bucket}/${script_s3_key} /tmp/hcp-must-gather.sh && bash /tmp/hcp-must-gather.sh"

    echo "  Launching log-collector task for HCP must-gather..."
    local run_task_output task_arn
    run_task_output=$(AWS_PAGER="" aws ecs run-task \
        --cluster "$ecs_cluster" \
        --task-definition "$task_def" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg_id],assignPublicIp=DISABLED}" \
        --overrides "$(jq -n \
            --arg cmd "$cmd" \
            --arg s3_bucket "$s3_bucket" \
            --arg s3_key "$s3_key" \
            --arg hcp_name "${HCP_CLUSTER_NAME:-}" \
            '{
                containerOverrides: [{
                    name: "log-collector",
                    command: [$cmd],
                    environment: [
                        {name: "S3_BUCKET",        value: $s3_bucket},
                        {name: "S3_KEY",           value: $s3_key},
                        {name: "HCP_CLUSTER_NAME", value: $hcp_name}
                    ]
                }]
            }')" \
        ) \
        || { echo "  Failed to launch log-collector task for ${cluster_id}"; \
             aws s3 rm "s3://${s3_bucket}/${script_s3_key}" --quiet || true; return 1; }

    local failures
    failures=$(echo "$run_task_output" | jq -r '.failures[0].reason // empty')
    if [[ -n "$failures" ]]; then
        echo "  ECS run-task failed for ${cluster_id}: $failures"
        aws s3 rm "s3://${s3_bucket}/${script_s3_key}" --quiet || true
        return 1
    fi

    task_arn=$(echo "$run_task_output" | jq -r '.tasks[0].taskArn // empty')
    if [[ -z "$task_arn" ]]; then
        echo "  ECS run-task returned no taskArn for ${cluster_id}"
        aws s3 rm "s3://${s3_bucket}/${script_s3_key}" --quiet || true
        return 1
    fi

    local task_id
    task_id=$(echo "$task_arn" | awk -F'/' '{print $NF}')
    echo "  Task started: $task_id"

    echo "  Waiting for must-gather task to finish..."
    if ! aws ecs wait tasks-stopped --cluster "$ecs_cluster" --tasks "$task_id"; then
        echo "  Waiter timed out; polling task status..."
        local poll_status=""
        for _ in $(seq 1 6); do
            poll_status=$(aws ecs describe-tasks \
                --cluster "$ecs_cluster" --tasks "$task_id" \
                --query 'tasks[0].lastStatus' --output text 2>/dev/null)
            [[ "$poll_status" == "STOPPED" ]] && break
            sleep 10
        done
        if [[ "$poll_status" != "STOPPED" ]]; then
            echo "  Task ${task_id} still not stopped (status: ${poll_status}); giving up"
            aws s3 rm "s3://${s3_bucket}/${script_s3_key}" --quiet || true
            return 1
        fi
    fi

    # Clean up the script from S3
    aws s3 rm "s3://${s3_bucket}/${script_s3_key}" --quiet || true

    local describe_output exit_code
    describe_output=$(aws ecs describe-tasks \
        --cluster "$ecs_cluster" --tasks "$task_id")
    exit_code=$(echo "$describe_output" | jq -r '.tasks[0].containers[0].exitCode // empty')

    if [[ -z "$exit_code" ]]; then
        local stop_reason
        stop_reason=$(echo "$describe_output" | jq -r '.tasks[0].stoppedReason // "unknown"')
        echo "  Warning: container never started for ${cluster_id} (reason: $stop_reason)"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    if [[ "$exit_code" != "0" ]]; then
        echo "  Warning: must-gather task exited with code $exit_code for ${cluster_id}"
        echo "  Check CloudWatch logs: /ecs/${cluster_id}/bastion (log-collector stream)"
        return 1
    fi

    if [[ "${S3_ONLY:-}" == "true" ]]; then
        echo "  HCP must-gather uploaded to S3. To download and extract:"
        echo ""
        echo "    mkdir -p /tmp/${cluster_id}-hcp-must-gather && \\"
        echo "    aws s3 cp s3://${s3_bucket}/${s3_key} /tmp/${cluster_id}-hcp-must-gather/${s3_key} && \\"
        echo "    tar xzf /tmp/${cluster_id}-hcp-must-gather/${s3_key} -C /tmp/${cluster_id}-hcp-must-gather"
        echo ""
        return 0
    fi

    echo "  Downloading HCP must-gather from S3..."
    local tmp_archive
    tmp_archive="$(mktemp -t hcp-must-gather-XXXXXX.tar.gz)"
    aws s3 cp "s3://${s3_bucket}/${s3_key}" "$tmp_archive" --quiet \
        || { echo "  Failed to download must-gather from S3 for ${cluster_id}"; rm -f "$tmp_archive"; return 1; }

    mkdir -p "$out_dir"
    if ! tar xzf "$tmp_archive" -C "$out_dir" --strip-components=1; then
        echo "  Failed to extract must-gather archive for ${cluster_id}; leaving S3 object intact"
        rm -f "$tmp_archive"
        return 1
    fi
    rm -f "$tmp_archive"

    aws s3 rm "s3://${s3_bucket}/${s3_key}" --quiet || true

    echo "==> ${cluster_id} HCP must-gather complete: ${out_dir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ -z "${CLUSTER_PREFIX+set}" ]]; then
    echo "ERROR: CLUSTER_PREFIX must be set (use empty string for bare cluster names)" >&2
    exit 0  # non-fatal so we don't mask test failures
fi

PREFIX="$CLUSTER_PREFIX"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${LOG_OUTPUT_DIR:-/tmp/${PREFIX:-cluster-}hcp-must-gather-${TIMESTAMP}}"

echo ""
echo "Collecting HCP must-gather from Management Cluster(s)..."
[[ -n "${HCP_CLUSTER_NAME:-}" ]] && echo "  Filtering to HCP cluster: ${HCP_CLUSTER_NAME}"

# Must-gather targets the management account (MC hosts HyperShift + HostedClusters)
export AWS_PROFILE="rrp-mc"

failed=0

mc_clusters=$(discover_mc_clusters "$PREFIX")
if [[ -z "$mc_clusters" ]]; then
    echo "  No management clusters found matching '${PREFIX}mc*'"
    exit 0
fi

while IFS= read -r mc_id; do
    mc_name="${mc_id#"$PREFIX"}"
    collect_must_gather_for_cluster "$mc_id" "${OUTPUT_DIR}/${mc_name}" || failed=1
done <<< "$mc_clusters"

# Redact sensitive values from downloaded logs
if [[ -d "$OUTPUT_DIR" ]]; then
    echo ""
    echo "Redacting sensitive values..."
    redact_logs "$OUTPUT_DIR"
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "HCP must-gather complete."
else
    echo "HCP must-gather finished with errors. Check output above for details."
fi

exit 0
