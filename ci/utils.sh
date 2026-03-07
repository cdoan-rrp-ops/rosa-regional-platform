#!/bin/bash

create_s3_bucket() {
    # Use environment variable if set, otherwise use default
    local bucket_name="e2e-rosa-regional-platform-${HASH}"
    local region="${TF_STATE_REGION:-us-east-1}"
    local account_id
    account_id="$(aws sts get-caller-identity --query Account --output text)" || return 1
    
    log_info "Setting up S3 backend: bucket=${bucket_name}, region=${region}, account=${account_id}"
    
    # Check if bucket exists
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log_info "Bucket ${bucket_name} already exists"
        
        # Verify bucket is in the expected region
        local bucket_region=$(aws s3api get-bucket-location --bucket "$bucket_name" --region us-east-1 --query LocationConstraint --output text 2>/dev/null || echo "")
        if [[ "$bucket_region" == "None" ]] || [[ "$bucket_region" == "null" ]] || [[ -z "$bucket_region" ]]; then
            bucket_region="us-east-1"
        fi
        if [[ "$bucket_region" != "$region" ]]; then
            log_error "Bucket ${bucket_name} exists in region ${bucket_region}, but expected ${region}"
            return 1
        fi
    else
        log_info "Creating bucket ${bucket_name} in region ${region}..."
        if [[ "$region" == "us-east-1" ]]; then
            # us-east-1 doesn't support LocationConstraint
            if ! aws s3api create-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null; then
                # Check if bucket was created by another process
                if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
                    log_info "Bucket ${bucket_name} was created by another process"
                else
                    log_error "Failed to create bucket ${bucket_name}"
                    return 1
                fi
            else
                log_success "Bucket ${bucket_name} created"
            fi
        else
            if ! aws s3api create-bucket \
                --bucket "$bucket_name" \
                --create-bucket-configuration LocationConstraint="$region" \
                --region "$region" 2>/dev/null; then
                # Check if bucket was created by another process
                if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
                    log_info "Bucket ${bucket_name} was created by another process"
                else
                    log_error "Failed to create bucket ${bucket_name}"
                    return 1
                fi
            else
                log_success "Bucket ${bucket_name} created"
            fi
        fi
    fi
    
    # Apply security settings (idempotent operations)
    log_info "Applying security settings to bucket ${bucket_name}..."
    
    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled \
        --region "$region" 2>/dev/null || log_info "Versioning already enabled"
    
    # Enable encryption
    aws s3api put-bucket-encryption \
        --bucket "$bucket_name" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$region" 2>/dev/null || log_info "Encryption already enabled"
    
    # Block public access
    aws s3api put-public-access-block \
        --bucket "$bucket_name" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$region" 2>/dev/null || log_info "Public access block already configured"
    
    # Apply bucket policy for cross-account access (if in AWS Organization)
    log_info "Applying bucket policy for cross-account access..."
    local org_id=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null || echo "")
    
    local policy_file=$(mktemp)
    if [[ -n "$org_id" ]]; then
        log_info "Detected AWS Organization: ${org_id}"
        cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOrganizationAccountAccess",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${bucket_name}",
        "arn:aws:s3:::${bucket_name}/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "${org_id}"
        }
      }
    }
  ]
}
EOF
    else
        log_info "Not in AWS Organization - applying account-restricted policy"
        cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllExceptAccount",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${bucket_name}",
        "arn:aws:s3:::${bucket_name}/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalAccount": "${account_id}"
        }
      }
    }
  ]
}
EOF
    fi
    
    aws s3api put-bucket-policy \
        --bucket "$bucket_name" \
        --policy "file://${policy_file}" \
        --region "$region" 2>/dev/null || log_info "Bucket policy already configured"
    
    rm -f "$policy_file"
    
    log_success "S3 backend configured: ${bucket_name} in ${region}"
}
