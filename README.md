# rosa-regional-platform

## Repository Structure

```
rosa-regional-platform/
├── terraform/
│   ├── modules/
│   │   └── eks-cluster/              # EKS cluster module with bootstrap capability
│   └── config/
│       ├── management-cluster/       # Management cluster configuration template
│       └── regional-cluster/         # Regional cluster configuration template
├── argocd/
│   ├── config/                       # Live Helm chart configurations
│   │   ├── management-cluster/       # Management cluster application templates
│   │   ├── regional-cluster/         # Regional cluster application templates
│   │   └── shared/                   # Shared configurations (ArgoCD, etc.)
│   ├── applicationset/               # ApplicationSet templates
│   ├── rendered/                     # Generated values and manifests
│   └── scripts/                      # Rendering and utility scripts
├── docs/
│   └── design-decisions/             # Design decision records
└── scripts/                          # Deployment and validation scripts
```

## Getting Started

### Cluster Provisioning

Quick start (regional cluster):
```bash
# One-time setup: Copy and edit configurations
cp terraform/config/regional-cluster/terraform.tfvars.example \
   terraform/config/regional-cluster/terraform.tfvars

# Provision complete regional cluster environment based on the .tfvars file
make provision-regional
```

Quick start (management cluster):
```bash
# One-time setup: Copy and edit configurations
cp terraform/config/management-cluster/terraform.tfvars.example \
   terraform/config/management-cluster/terraform.tfvars

# Provision complete management cluster environment based on the .tfvars file
make provision-management
```

### Available Make Targets

For all `make` targets, see `make help`.