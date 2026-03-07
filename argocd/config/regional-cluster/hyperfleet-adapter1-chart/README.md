# HyperFleet Adapter Chart - ArgoCD Application Wrapper

This Helm chart creates an ArgoCD Application resource that deploys the HyperFleet Adapter Helm chart from an external Git repository.

## Purpose

This chart is a wrapper that allows the ArgoCD ApplicationSet to manage an Application pointing to the external [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) charts. The adapter consumes CloudEvents from message brokers (GCP Pub/Sub, RabbitMQ), processes AdapterConfig, manages Kubernetes resources, and reports status via the HyperFleet API.

## Architecture

```
ApplicationSet (base-applicationset.yaml)
  └─> hyperfleet-adapter1-chart (this chart)
      └─> ArgoCD Application Resource
          └─> External HyperFleet Adapter Helm Chart
              └─> Kubernetes Resources (Deployment, ConfigMaps, etc.)
```

## Configuration

### Default Values

```yaml
hyperfleetAdapter1Chart:
  name: hyperfleet-adapter1
  namespace: argocd
  targetNamespace: hyperfleet-system
  source:
    repoURL: https://github.com/openshift-hyperfleet/hyperfleet-adapter
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

- `hyperfleetAdapter1Chart.name` - Name of the ArgoCD Application resource
- `hyperfleetAdapter1Chart.targetNamespace` - Where the adapter will be deployed
- `hyperfleetAdapter1Chart.source.targetRevision` - Git branch/tag to deploy from
- `hyperfleetAdapter1Chart.values` - Helm values passed to the external chart (image, adapterConfig.hyperfleetApi.baseUrl, broker.*, rbac, etc.)

Override `hyperfleetAdapter1Chart.values.adapterConfig.hyperfleetApi.baseUrl` if the HyperFleet API is in a different namespace or host. Override `broker.googlepubsub` or `broker.rabbitmq` for your message broker configuration.

## Deployment

This chart is automatically deployed by the ArgoCD ApplicationSet when placed in the `argocd/config/regional-cluster/` directory. The ApplicationSet will create an ArgoCD Application that renders this Helm chart, which in turn creates another ArgoCD Application pointing to the external repository.

## Source Repository

The external HyperFleet Adapter Helm chart is located at:
https://github.com/openshift-hyperfleet/hyperfleet-adapter/tree/main/charts
