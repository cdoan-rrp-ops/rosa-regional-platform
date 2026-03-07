# HyperFleet API Chart - ArgoCD Application Wrapper

This Helm chart creates an ArgoCD Application resource that deploys the HyperFleet API Helm chart from an external Git repository.

## Purpose

This chart is a wrapper that allows the ArgoCD ApplicationSet to manage an Application pointing to an external Helm chart repository. Instead of directly deploying Kubernetes resources, this chart creates an ArgoCD Application manifest that references the upstream HyperFleet API charts.

## Architecture

```
ApplicationSet (base-applicationset.yaml)
  └─> hyperfleet-api-chart (this chart)
      └─> ArgoCD Application Resource
          └─> External HyperFleet API Helm Chart
              └─> Kubernetes Resources
```

## Configuration

### Default Values

```yaml
hyperfleetApiChart:
  name: hyperfleet-api-external
  namespace: argocd
  targetNamespace: hyperfleet-system
  source:
    repoURL: https://github.com/openshift-hyperfleet/hyperfleet-api
    targetRevision: main
    path: charts
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Customization

You can customize the deployment by overriding values:

- `hyperfleetApiChart.name` - Name of the ArgoCD Application resource
- `hyperfleetApiChart.targetNamespace` - Where HyperFleet API will be deployed
- `hyperfleetApiChart.source.targetRevision` - Git branch/tag to deploy from
- `hyperfleetApiChart.values` - Additional Helm values to pass to the external chart

### External database

When `hyperfleetApiChart.values.database.external.enabled` is true, the external chart expects a Kubernetes Secret in the target namespace. Set `hyperfleetApiChart.values.database.external.secretName` to the name of that Secret. The Secret must contain keys: `db.host`, `db.port`, `db.name`, `db.user`, `db.password`. Create it via SecretProviderClass `secretObjects`, External Secrets Operator, or manually.

## Deployment

This chart is automatically deployed by the ArgoCD ApplicationSet when placed in the `argocd/config/regional-cluster/` directory. The ApplicationSet will create an ArgoCD Application that renders this Helm chart, which in turn creates another ArgoCD Application pointing to the external repository.

## Source Repository

The external HyperFleet API Helm chart is located at:
https://github.com/openshift-hyperfleet/hyperfleet-api/tree/main/charts
