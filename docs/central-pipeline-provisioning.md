# Complete Guide: Provision a New Central Pipeline

This comprehensive guide walks through all steps to provision a new central pipeline in the ROSA Regional Platform. Follow these steps in order to set up a central pipeline that will provision both Regional and Management Clusters with full ArgoCD configuration and Maestro connectivity.

---

## 1. Pre-Flight Checklist

Before starting, ensure your environment is properly configured.

### Required Tools

Verify all tools are installed and accessible:

```bash
# Check tool versions
aws --version
terraform --version
python --version  # or python3 --version
jq
```

You also must be able to access the `Central` account AWS console.

For us, you can go to `rover > AWS IAAS > 811....-rrp-admin > login > then switch` by account id to your `Central` account

### 1.1 Required AWS accounts

To provision a regional and management cluster, you require three AWS accounts:
* one account for the `Central` configuration
* one account for the `Regional` Cluster
* one account for the `Management` Cluster

Ensure you have access to the designated Central account via environment variables or ideally AWS profiles.

The 2 accounts designated for the `Regional` Cluster and `Management` Cluster require additional assume-role configuration from the `Central` if it not already able to assume-role.

### 1.2 Enable Assume-Role

Add the Central AWS account number to the trust policy of `OrganizationAccountAccessRole` in the 2 regional and management accounts.

**: Using jq to programmatically add the account:**

```bash
# Set variables
CENTRAL_ACCOUNT_ID="123456789012"
ROLE_NAME="OrganizationAccountAccessRole"

# Get current trust policy and add Central account
aws iam get-role --role-name $ROLE_NAME --query 'Role.AssumeRolePolicyDocument' --output json | \
  jq --arg account "arn:aws:iam::${CENTRAL_ACCOUNT_ID}:root" \
  '.Statement[0].Principal.AWS |= (if type == "array" then (. + [$account] | unique) else [., $account] | unique end)' \
  > /tmp/trust-policy-updated.json

# Update the role trust policy
aws iam update-assume-role-policy \
  --role-name $ROLE_NAME \
  --policy-document file:///tmp/trust-policy-updated.json

# Repeat the same steps for the Management Cluster account
# (Switch AWS profile/credentials to the Management Cluster account first)
```

## 2. Define a new Sector/Region Configuration

> **Note:** In case you are deploying clusters based on existing argocd configuration, you can skip this step.
Example: You want to spin up a development cluster and re-use the existing configuration for `env = integration` and `region = us-east-1`.

### 2.1 Define a sector configuration

Edit the `config.yaml` and add a new sector configuration like below. 

New sectors are defined under the `sectors` object. The sector `name` is abitrary. The `environment` parameter is important because it denotes the association of a central account to a single pipeline that manages that central account.
There is a pipeline to manage a central account. Each region will have its own pipeline.

In the example snippet below, an arbitary sector name `brian-testing` is defined, and associated to a `brian-central` environment. A single central account will be associated to the `brian-central` environment. If there are multiple `brian-central` environments defined, there will be conflicts.

```yaml
sectors:
  # ... existing entries ...
  - name: "brian-testing"
    environment: "brian-central"
    terraform_vars:
      app_code: "infra"
      service_phase: "dev"
      cost_center: "000"
      environment: "{{ environment }}"
    values:
      management-cluster:
        hypershift:
          oidcStorageS3Bucket:
            name: "hypershift-mc-{{ aws_region }}"
            region: "{{ aws_region }}"
          externalDns:
            domain: "dev.{{ aws_region }}.rosa.example.com"
```

### 2.2 Define a region configuration

Edit `config.yaml` and add a region configuration and associate to a sector.
* There can be multiple regions to an `environment`
* There can be multiple regions to a `sector`

```yaml
region_deployments:
  # ... existing entries ...
  - name: "us-east-1"
    aws_region: "us-east-1"
    sector: "brian-testing"
    account_id: "<Regional account>"
    terraform_vars:
      account_id: "{{ account_id }}"
      region: "{{ aws_region }}"
      alias: "regional-{{region_deployment}}"
      region_deployment: "{{ region_deployment }}"
      enable_bastion: true
    management_clusters:
      - cluster_id: "mc01-{{ region_deployment }}"
        account_id: "<Management Account>"
```

> NOTE: If you want to enable the bastion module, add the `enable_bastion: true` to your region deployment and re-render.

### 2.3 Generate Rendered Configurations

Run the rendering script to generate the configurations to be deployed by the pipeline:

```bash
./scripts/render.py
```

**Verify rendered files were created:**

```bash
ls -la deploy/<sector>/<region>/  # Replace with your environment/name
```

You should see `argocd/` and `terraform/` subdirectories with generated configs.

### 2.4 Commit and Push Changes

```bash
git add config.yaml deploy/
git commit -m "Add <region> region configuration"
git push origin <your-branch>
```

---

## 3. Bootstrap the Central Pipeline

This step will create the codepipelines in the `Central` account. Switch to your `Central` AWS profile and run the commands below to create the pipelines.

### 3.1 Execute central pipeline bootstrap

```bash
# Authenticate with central account (choose your preferred method)
export AWS_PROFILE=<central-profile>
# OR: aws configure set profile <regional-profile>
# OR: use your SSO/assume role method

# Bootstrap the pipeline
GITHUB_REPOSITORY=<ORG>/rosa-regional-platform GITHUB_BRANCH=<BRANCH> TARGET_ENVIRONMENT=<SECTOR> ./scripts/bootstrap-central-account.sh

# Example
GITHUB_REPOSITORY=cdoan1/rosa-regional-platform GITHUB_BRANCH=process-doc TARGET_ENVIRONMENT=cdoan-central ./scripts/bootstrap-central-account.sh

```

### 3.2 Accept the Codestar connection

The tf script will run to completion with the last message like below, but the pipeline will have an error and block.

```bash
===================================================
✅ Bootstrap Complete!
===================================================

🔗 GitHub Connection Authorization:
   1. Open AWS Console: https://console.aws.amazon.com/codesuite/settings/connections
   2. Find connections in PENDING state
   3. Click 'Update pending connection' and authorize with GitHub
```

You must accept the CodeStar connection to establish oauth between github and the pipeline, using the AWS Console.

Log into the Central AWS Account console, by way of the [AWS SSO page](https://auth.redhat.com/auth/realms/EmployeeIDP/protocol/saml/clients/itaws).  

`Developer Tools` > `Settings` > `Connections` > `Accept the pending connection`

Since the pipeline was deployed before the connection was accepted, you must retrigger the `CodePipeline` in the aws console.

The `pipeline-provisioner` is the first pipeline. Once this completes successfully, you should see the creation of the `rc-pipe-XXX` and `mc-pipe-XXX` pipelines.

At any point, you can retrigger a pipeline by going to the CodePipeline > Pipeline view select a pipeline like `pipeline-provisioner` and click `Release change` button. If you branch has new changes, the pipeline will fetch the latest SHA and run.

### 3.3 Pipeline can be triggered from the aws cli


```bash
aws codepipeline start-pipeline-execution --name MyFirstPipeline --variables name=var1,value=1 name=var2,value=2
```

Example trigger RC pipeline

```
# from the central account, get the list of pipelines available
aws codepipeline list-pipelines \
  --query 'pipelines[*].[name,created,updated]' \
  --output table
--------------------------------------------------------------------------------------------------
|                                          ListPipelines                                         |
+----------------------+------------------------------------+------------------------------------+
|  mc-pipe-fa50acc785e1|  2026-02-19T12:00:21.529000-06:00  |  2026-02-19T12:00:21.529000-06:00  |
|  pipeline-provisioner|  2026-02-19T11:09:03.855000-06:00  |  2026-02-19T11:09:03.855000-06:00  |
|  rc-pipe-1f570faa867c|  2026-02-19T11:59:06.179000-06:00  |  2026-02-19T11:59:06.179000-06:00  |
+----------------------+------------------------------------+------------------------------------+

# trigger the pipeline. this trigger will referesh the source repo to the latest commit
aws codepipeline start-pipeline-execution --name rc-pipe-1f570faa867c
{
    "pipelineExecutionId": "f54ab63b-f317-4300-9f1a-a371cc92e55f"
}
```

> NOTE: In `rc-pipe-1f570faa867c`, `1f570faa867c` is just a hash of static string

### 3.4 Connect to the bastion (Optional)

If you enabled the bastion, you can verify the state of the `Regional` cluster directly.

```bash
# switch to your regional account
export AWS_PROFILE=rrp-chris-regional_cluster

CLUSTER=$(aws ecs list-clusters | jq -r '.clusterArns[]' | cut -d'/' -f2 | grep bastion)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID --container bastion --interactive --command '/bin/bash'
```

### 3.5 From the bastion, verify Applcations

```bash
kubectl get applications -A
NAMESPACE   NAME                SYNC STATUS   HEALTH STATUS
argocd      argocd              Synced        Healthy
argocd      hyperfleet-system   Synced        Healthy
argocd      maestro-server      Synced        Healthy
argocd      platform-api        Synced        Healthy
argocd      root                Synced        Healthy
```

### 3.5 Verify the Platform API

We need to connect to s3 to get the tf output.

```bash
export AWS_PRIFILE=central_account

# navigate to the tf template
cd terraform/config/pipeline-regional-cluster/

CENTRAL_ACCOUNT=724701986097

terraform init -reconfigure \
  -backend-config="bucket=terraform-state-$CENTRAL_ACCOUNT" \
  -backend-config="key=regional-cluster/regional-us-east-2.tfstate" \
  -backend-config="region=us-east-2"

# extract the test command with the api gateway endpoint from output
terraform output -raw api_test_command
awscurl --service execute-api --region us-east-2 \
  https://kycvifaakj.execute-api.us-east-2.amazonaws.com/prod/v0/live

# query the platform api status
awscurl --service execute-api --region us-east-2 \
  https://kycvifaakj.execute-api.us-east-2.amazonaws.com/prod/v0/live
{"status":"ok"}
```

> NOTE: to awscurl any of the api endpoints, you need to be logged into the regional account to run. As by default, we have only automatically authz the regional account id to have priviledge access.

## 4. Verify Maestro Connectivity

Maestro uses AWS IoT Core for secure MQTT communication between Regional and Management Clusters. This requires a two-account certificate exchange process.


**What this creates:**
- Kubernetes secret containing IoT certificate and endpoint
- Configuration for Maestro agent to connect to regional IoT endpoint

```bash
export AWS_PROFILE=rrp-chris-regional_cluster

# In regional account - verify IoT endpoint
aws iot describe-endpoint --endpoint-type iot:Data-ATS

# Check certificate is active
aws iot list-certificates | jq -r '.certificates[].status'
ACTIVE
ACTIVE
ACTIVE
```

## 5. Management Cluster Provisioning

### 5.1 Verify Management Cluster Provisioning

```bash
# Authenticate with management account (choose your preferred method)
export AWS_PROFILE=central

aws s3 ls terraform-state-724701986097/management-cluster/
2026-02-19 16:14:10     168127 mc01-us-east-2.tfstate

CENTRAL=724701986097
terraform init -reconfigure \
  -backend-config="bucket=terraform-state-$CENTRAL" \
  -backend-config="key=management-cluster/mc01-us-east-2.tfstate" \
  -backend-config="region=us-east-2"

# Connect to the bastion for the management cluster
CLUSTER=$(aws ecs list-clusters | jq -r '.clusterArns[]' | cut -d'/' -f2 | grep bastion)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[0]' --output text | awk -F'/' '{print $NF}')
aws ecs execute-command --cluster $CLUSTER --task $TASK_ID --container bastion --interactive --command '/bin/bash'

# if the TASK_ID is empty, the fargate task has not run, you can get this from the tf output above
aws ecs run-task \
  --cluster mc01-us-east-2-bastion \
  --task-definition mc01-us-east-2-bastion \
  --launch-type FARGATE \
  --enable-execute-command \
  --network-configuration 'awsvpcConfiguration={subnets=[subnet-064ea8d2f30df1dac,subnet-04a037bfeefaf359e,subnet-0d0e765fc2f37fd7e],securityGroups=[sg-0d62c0eea4129e0f1],assignPublicIp=DISABLED}'

# query the applications on the management cluster
oc get applications -A
NAMESPACE   NAME            SYNC STATUS   HEALTH STATUS
argocd      argocd          Synced        Healthy
argocd      cert-manager    Synced        Healthy
argocd      hypershift      Synced        Healthy
argocd      maestro-agent   Synced        Healthy
argocd      root            Synced        Healthy
```

---
The pipeline process current ends here.  For the remaining manual directions, follow [Consumer Registration & Verification](https://github.com/openshift-online/rosa-regional-platform/blob/main/docs/full-region-provisioning.md#6-consumer-registration--verification)
