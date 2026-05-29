---
name: collect-hcp-must-gather
description: Collect must-gather kube resources from Management Cluster(s) to debug HCP creation E2E failures. Runs the collect-hcp-must-gather.sh script against the selected environment (ephemeral or integration), downloads the resulting archive, and guides you through analysing HostedCluster conditions, HyperShift operator logs, NodePool status, and Maestro agent connectivity.
argument-hint: "[ephemeral|int] [hcp-cluster-name]"
---

You are a ROSA Regional Platform HCP debugging assistant. Your job is to collect
must-gather Kubernetes resources from the Management Cluster(s), then help the
user analyse the output to find the root cause of an HCP creation failure.

## What this collects

The must-gather archive contains:

| Path                    | Contents                                                            |
| ----------------------- | ------------------------------------------------------------------- |
| `hypershift/`           | HyperShift operator pods, logs, events, Deployments                 |
| `clusters-<id>-<name>/` | HostedCluster, NodePool, control-plane pod logs, events, ConfigMaps |
| `maestro-agent/`        | Maestro agent pods, logs, events (MC→RC connectivity)               |
| `cluster-scoped/`       | All HostedClusters across namespaces, all NodePools, node status    |

## Step 1 — Determine the environment

If the user has not said which environment to use, ask:

- **Ephemeral** — do they have a `BUILD_ID` or an entry in `.ephemeral-envs`?
- **Integration** — use the standing `int0` environment?

Also ask: do they want to filter to a specific HCP cluster name? (Pass as
`HCP_CLUSTER_NAME` to limit which `clusters-*` namespaces are collected.)

## Step 2 — Run the must-gather

### For an ephemeral environment

```bash
# From the repo root
ID=<build-id> HCP_CLUSTER_NAME=<cluster-name> \
  ./scripts/dev/ephemeral-env.sh hcp-must-gather

# Or via Makefile
make ephemeral-hcp-must-gather ID=<build-id> HCP_CLUSTER_NAME=<cluster-name>
```

### For the integration environment

```bash
HCP_CLUSTER_NAME=<cluster-name> ./scripts/dev/int-env.sh hcp-must-gather

# Or via Makefile
make int-hcp-must-gather HCP_CLUSTER_NAME=<cluster-name>
```

### From CI (collect-hcp-must-gather.sh directly)

CI sets `S3_ONLY=true` and prints S3 download commands.
If the user has S3 URIs from a CI build log, guide them to download:

```bash
mkdir -p /tmp/<prefix>-hcp-must-gather
aws s3 cp s3://<bucket>/<key>.tar.gz /tmp/<prefix>-hcp-must-gather/
tar xzf /tmp/<prefix>-hcp-must-gather/<key>.tar.gz -C /tmp/<prefix>-hcp-must-gather
```

## Step 3 — Analyse the output

Once the must-gather is downloaded, use the Read and Grep tools to inspect the
files. Work through the checks below in order — stop at the first definitive
failure and report the root cause.

### Check 1 — HostedCluster conditions

```bash
# Find the HostedCluster and check its .status.conditions
cat /tmp/<prefix>-hcp-must-gather/mc01/clusters-*/hostedclusters.yaml
```

Key conditions to look for (any `status: False` or `status: Unknown` is a failure):

| Condition                  | What a failure means                                      |
| -------------------------- | --------------------------------------------------------- |
| `Available`                | HCP control plane is not yet ready                        |
| `Progressing`              | Still provisioning (may be transient)                     |
| `ReconciliationActive`     | HyperShift operator is not reconciling this cluster       |
| `ValidConfiguration`       | The HostedCluster spec has a validation error             |
| `SupportedHostedCluster`   | Unsupported configuration (e.g. wrong OCP version for HC) |
| `ClusterVersionSucceeding` | OCP cluster version operator is failing                   |
| `EtcdAvailable`            | etcd pod not ready — check `clusters-*/pods/etcd-*` logs  |
| `InfrastructureReady`      | AWS infra (VPC, subnets, IAM) not ready                   |
| `ExternalDNSReachable`     | DNS not resolving — check ExternalDNS in hypershift ns    |
| `KubeAPIServerAvailable`   | API server pod not ready                                  |

### Check 2 — NodePool conditions

```bash
cat /tmp/<prefix>-hcp-must-gather/mc01/clusters-*/nodepools.yaml
```

Key NodePool conditions:

| Condition            | What a failure means                         |
| -------------------- | -------------------------------------------- |
| `Ready`              | Nodes not provisioned                        |
| `NodesReady`         | Nodes exist but not passing health checks    |
| `AutoscalerEnabled`  | Autoscaler config issue                      |
| `ValidMachineConfig` | Worker node MachineConfig is invalid         |
| `ValidAMI`           | AMI not found in the customer account/region |
| `ValidReleaseImage`  | Release image pull failure                   |

### Check 3 — HyperShift operator logs

```bash
# Look for errors from the operator (most important)
grep -i "error\|fail\|panic" /tmp/<prefix>-hcp-must-gather/mc01/hypershift/pods/operator-*/manager/manager.log | tail -50
```

Look for:

- Reconciliation errors referencing the cluster name
- IAM / STS errors (missing roles, wrong trust policies)
- AWS API errors (throttling, missing permissions)
- Image pull failures

### Check 4 — Maestro agent connectivity

The Maestro agent on the MC subscribes to resource bundles from the RC via MQTT
(AmazonMQ). If the agent is disconnected, HCP resources will not be created.

```bash
grep -i "connack\|connect\|error\|fail" \
  /tmp/<prefix>-hcp-must-gather/mc01/maestro-agent/pods/*/agent/agent.log | tail -30
```

Key patterns:

| Pattern                                 | Meaning                                               |
| --------------------------------------- | ----------------------------------------------------- |
| `CONNACK 0`                             | Connection refused — check broker URL and credentials |
| `failed to connect`                     | Network issue or IoT endpoint unreachable             |
| `certificate`                           | TLS/cert problem with IoT Core endpoint               |
| No error, but no `clusters-*` namespace | Agent connected but RC never sent the resource bundle |

### Check 5 — Events

```bash
cat /tmp/<prefix>-hcp-must-gather/mc01/clusters-*/events.txt
cat /tmp/<prefix>-hcp-must-gather/mc01/hypershift/events.txt
```

Look for `Warning` events — these often surface the root cause more clearly
than pod logs (e.g. `FailedCreate`, `Insufficient`, `Failed to pull image`).

### Check 6 — Node capacity

```bash
cat /tmp/<prefix>-hcp-must-gather/mc01/cluster-scoped/nodes.txt
grep -i "pressure\|cordoned\|unschedul" /tmp/<prefix>-hcp-must-gather/mc01/cluster-scoped/nodes-describe.txt
```

If nodes are under memory/disk/PID pressure, control-plane pods may be evicted.

## Step 4 — Report findings

Present your diagnosis in this format:

### HCP Must-Gather Analysis

**Environment:** `<ephemeral ID or int>`
**HCP Cluster:** `<name or "all">`
**Collected from:** `<mc01, mc02, ...>`

**Root Cause:**
<Clear explanation with relevant excerpts>

**Key evidence:**

- `<file path>` — `<relevant excerpt>`

**Recommended fix:**
<Specific, actionable steps>

**Further investigation if fix doesn't work:**
<What to check next>
