# RHACM GitOps Multi-Tenancy Demo

Fleet-wide GitOps using Red Hat Advanced Cluster Management (RHACM 2.15) and OpenShift GitOps with the **Principal/Agent** architecture. A central ArgoCD Principal on the hub streams Application specs to lightweight Agents on each spoke cluster. Agents reconcile locally and stream status back — no spoke credentials stored on the hub, no inbound firewall rules needed.

## Architecture

```mermaid
graph TB
    subgraph hub [Hub Cluster - fleet-gitops namespace]
        Principal[ArgoCD Principal<br/>controller disabled]
        AppSets[ApplicationSets]
        UI[ArgoCD UI<br/>Single Pane of Glass]
        Principal --> AppSets
        Principal --> UI
    end

    subgraph blueSpoke [blue-cluster]
        BlueAgent[ArgoCD Agent]
    end

    subgraph redSpoke [red-cluster]
        RedAgent[ArgoCD Agent]
    end

    BlueAgent -->|"gRPC mTLS (outbound)"| Principal
    RedAgent -->|"gRPC mTLS (outbound)"| Principal
    Principal -.->|Stream specs| BlueAgent
    Principal -.->|Stream specs| RedAgent
    BlueAgent -.->|Stream status| Principal
    RedAgent -.->|Stream status| Principal
```

### Key Properties

- **Zero-trust** — Spokes initiate all connections; hub stores no spoke credentials
- **Decentralized reconciliation** — Each Agent applies manifests locally
- **Multi-tenant** — AppProjects scope tenant teams to their own applications
- **Self-healing** — Agents auto-revert local drift
- **Scalable** — Adding a cluster = deploy Agent + cert, it auto-joins the fleet

## Branch Strategy

| Branch | Architecture | Status |
|--------|-------------|--------|
| `main` | Push model (centralized fleet-argocd) | Legacy |
| `fleetdev` | **Principal/Agent** (pull-based, mTLS) | Active |

## Prerequisites

- 1 OpenShift hub cluster with RHACM 2.15+ installed
- [OpenShift GitOps operator >= 1.19](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html/release_notes/gitops-release-notes) (ArgoCD Agent GA)
- AWS credentials for spoke cluster provisioning
- OpenShift pull secret
- OpenShift Platform Plus subscription (for agent clusters)

## Quick Start (One Command)

```bash
# 1. Login to hub
oc login --token=<token> --server=https://<hub-api>:6443

# 2. Deploy everything
bash scripts/deploy-demo.sh
```

The orchestrator auto-detects your environment (base domain, Keycloak, AWS credentials) and deploys users, GitOps operator, Principal, spoke clusters, mTLS, agents, and applications.

**Options:**
- `--skip-clusters` — Skip spoke provisioning (if clusters already exist)
- `--skip-users` — Skip user/auth setup
- `--dry-run` — Preview without executing
- `--password <PASS>` — Custom demo user password

For RHPDS environments, see [docs/rhpds-quickstart.md](docs/rhpds-quickstart.md).

<details>
<summary>Manual Deployment (step-by-step)</summary>

```bash
# 1. Deploy users, groups, and ACM policies
bash scripts/setup-users.sh
oc apply -k ./AcmPolicies/InstallGitOpsOperator
oc apply -k ./AcmPolicies/FleetArgoCD
oc apply -k ./AcmPolicies/RegisterAllClustersToFleet

# 2. Provision spoke clusters (requires AWS credential)
bash cluster-provisioning/pre-deploy-check.sh
oc apply -f cluster-provisioning/blue-cluster.yaml
oc apply -f cluster-provisioning/red-cluster.yaml

# 3. Setup mTLS and deploy agents (after clusters are ready)
bash scripts/setup-agent-tls.sh \
  --blue-kubeconfig /tmp/blue-cluster-kubeconfig \
  --red-kubeconfig /tmp/red-cluster-kubeconfig

# 4. Deploy ApplicationSets
oc apply -k ./ApplicationSets/fleet
```

For the full step-by-step guide, see [docs/deployment-guide.md](docs/deployment-guide.md).

</details>

## Repository Structure

```
.
├── kustomization.yaml                         # Hub resources (UsersGroups + AcmPolicies)
├── AcmPolicies/
│   ├── InstallGitOpsOperator/                 # Install GitOps operator on hub
│   ├── ArgoCDInstances/                       # Per-tenant ArgoCD instances (optional)
│   ├── RegisterClustersToArgoCDInstances/     # Register per-tenant clusters (optional)
│   ├── FleetArgoCD/                           # fleet-argocd Principal instance
│   └── RegisterAllClustersToFleet/            # GitOpsCluster + Placements + RBAC
├── ApplicationSets/fleet/                     # AppProjects + ApplicationSets
├── PlatformConfig/baseline/                   # Spoke platform config (LimitRange, NetworkPolicy)
├── UsersGroups/                               # OAuth users, groups, HTPasswd
├── cluster-provisioning/                      # Hive ClusterDeployment YAMLs for AWS
├── agents/                                    # ArgoCD Agent CRs + NetworkPolicies
├── certs/                                     # mTLS certificate generation
└── docs/                                      # Detailed documentation
```

## Documentation

| Document | Audience | Description |
|----------|----------|-------------|
| [RHPDS Quickstart](docs/rhpds-quickstart.md) | Engineers | One-command deployment on RHDP environments |
| [Architecture](docs/architecture.md) | Stakeholders | High-level architecture, diagrams, GA status |
| [Control Flow](docs/control-flow.md) | Stakeholders + Engineers | How the Principal manages Agents, lifecycle flows |
| [Deployment Guide](docs/deployment-guide.md) | Engineers | Full step-by-step operational runbook |
| [Cluster Provisioning](docs/cluster-provisioning.md) | Engineers | AWS Hive provisioning guide |
| [User Management](docs/user-management.md) | Engineers | Keycloak/htpasswd auth configuration |
| [Troubleshooting](docs/troubleshooting.md) | Engineers | Common issues and resolutions |

## Access Summary

| User | Group | Sees in fleet-argocd UI |
|------|-------|-------------------------|
| acmsre1 | acm-sre-group | All applications across all clusters |
| bluesre1 | blue-sre-group | `mobileapp-*` applications only |
| redsre1 | red-sre-group | `galaga-*` applications only |

## References

- [OpenShift GitOps 1.19 Release Notes (ArgoCD Agent GA)](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html/release_notes/gitops-release-notes)
- [ArgoCD Agent Architecture Overview](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html/argo_cd_agent_architecture/argocd-agent-architecture)
- [ArgoCD Agent Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/argo_cd_agent_installation/)
- [Fleet-Scale GitOps Control Flow with RHACM](https://medium.com/@tcij1013/fleet-scale-gitops-control-flow-with-red-hat-advanced-cluster-management-0eca855136c3)
- [RHACM Workshop — Module 01](https://tosin2013.github.io/rhacm-workshop/modules/01-installation.html)
- [RHACM Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.15)
- [OpenShift GitOps Documentation](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)
- [RHPDS ACM Demo Catalog](https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/published.ocp4-acm-demo.prod)
