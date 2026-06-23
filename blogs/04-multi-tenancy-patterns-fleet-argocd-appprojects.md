---
title: "Multi-tenancy patterns for fleet-wide ArgoCD with AppProjects"
seo_meta_title: "Multi-tenancy patterns for fleet-wide ArgoCD AppProjects"
seo_meta_description: "Learn how to isolate teams on a single ArgoCD instance at fleet scale using AppProjects, RBAC groups, and Red Hat Advanced Cluster Management Placements."
url_slug: /blog/multi-tenancy-patterns-fleet-argocd-appprojects
primary_keyword: multi-tenancy ArgoCD AppProjects
secondary_keywords:
  - fleet-scale GitOps
  - RHACM multi-cluster RBAC
  - ArgoCD Principal/Agent tenant isolation
  - OpenShift GitOps multi-tenancy
series: "Fleet-scale GitOps with RHACM"
series_position: 4 of 5
template: Explainer
word_count_target: 800–1,300
---

## Multi-tenancy patterns for fleet-wide ArgoCD with AppProjects

*This is post 4 of 5 in the series "Fleet-scale GitOps with RHACM."*

When you hand a single ArgoCD instance to three teams, someone is going to deploy to the wrong cluster by Friday. I have watched it happen. A well-intentioned engineer syncs a staging manifest to production because nothing in the system told them they couldn't. Multi-tenancy is not a nice-to-have at fleet scale — it is the thing that keeps your Friday evenings peaceful.

In this post, I walk through the patterns I use to carve a single Red Hat OpenShift GitOps ArgoCD instance into isolated tenant lanes using AppProjects, role-based access control (RBAC) groups, and Red Hat Advanced Cluster Management for Kubernetes Placements. If you have been following this series, you already have a Principal/Agent architecture running across multiple clusters. Now we make sure each team can only touch what belongs to them.

## What multi-tenancy means in a fleet context

Multi-tenancy, in the context of ArgoCD, means multiple teams share the same control plane while each team can only see and manage its own applications, repositories, and target clusters. The alternative — spinning up a dedicated ArgoCD instance per team — sounds clean on a whiteboard, but creates an operational burden that grows linearly. You end up managing dozens of upgrades, separate RBAC policies, and disconnected dashboards.

A better approach is logical partitioning. One ArgoCD Principal on the hub serves as the single pane of glass, with AppProjects drawing hard boundaries between tenants. Each team gets its own project with its own RBAC roles, allowed sources, and destination constraints. From the outside it looks like each team has its own ArgoCD. Under the hood, you manage one.

## Key concepts and components

### AppProjects as the tenancy boundary

An AppProject is where you define what a tenant is allowed to do. Three fields do most of the work: `sourceRepos` controls which Git repositories the tenant can pull from, `destinations` controls which clusters and namespaces they can deploy to, and `clusterResourceWhitelist` controls which cluster-scoped resources they can create.

Here is the AppProject for the blue team in our demo environment:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: blue-team
  namespace: fleet-gitops
spec:
  description: Blue team tenant applications
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
      name: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  roles:
    - name: admin
      description: Blue team admin
      policies:
        - p, proj:blue-team:admin, applications, *, blue-team/*, allow
      groups:
        - blue-sre-group
    - name: readonly
      description: Blue team readonly
      policies:
        - p, proj:blue-team:readonly, applications, get, blue-team/*, allow
      groups:
        - blue-viewer-group
```

The `roles` section is the critical piece. Each role carries Casbin-style policy strings that scope permissions to applications within the `blue-team` project. The `groups` field binds those roles to OpenShift OAuth groups, which means your existing identity provider handles authentication while ArgoCD handles authorization.

### RBAC groups and the four-group model

I use a four-group model per tenant: an SRE group with full admin privileges, a viewer group with read-only access, and then a parallel pair at the platform level for cluster-wide visibility. In YAML, the groups are straightforward OpenShift Group objects:

```yaml
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: blue-sre-group
users:
  - bluesre1
---
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: acm-sre-group
users:
  - acmsre1
```

The `acm-sre-group` has admin access to the `default` AppProject, which contains platform-baseline applications that deploy to every cluster. The `blue-sre-group` only has access to `blue-team` applications. When `bluesre1` logs into the ArgoCD UI, they see their mobile app deployments and nothing else.

### Placements and cluster sets as the targeting layer

AppProjects define *who* can do *what*. Red Hat Advanced Cluster Management for Kubernetes Placements define *where*. A Placement resource selects clusters by label, and an ApplicationSet uses a `clusterDecisionResource` generator to turn those Placement decisions into per-cluster Application custom resources (CRs). This is the bridge between RBAC and actual deployment topology.

## How it works end to end

### The dual-location requirement

In the Principal/Agent model, AppProjects must exist in two places: on the hub (where the Principal enforces RBAC for the UI and API) and on each spoke (where the Agent's application controller needs the project definition to validate syncs). The Principal streams AppProject definitions to agents automatically based on the `destinations[].name` field, so you only author them once on the hub.

### Blue team mobile app: six steps from Git to cluster

Here is the end-to-end flow when the blue team pushes a change to their mobile application repository:

1. **Placement resolves targets.** The `blue-placement` resource on the hub selects clusters in the `blueclusterset` ManagedClusterSet. Today that is `blue-cluster`, but adding a new cluster is just a label change.
2. **ApplicationSet generates Application CRs.** The `mobile-application-set` uses a `clusterDecisionResource` generator to watch the Placement decisions and template one Application per matching cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: mobile-application-set
  namespace: fleet-gitops
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: acm-placement
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/placement: blue-placement
        requeueAfterSeconds: 180
  template:
    metadata:
      name: mobileapp-{{name}}
    spec:
      project: blue-team
      source:
        repoURL: https://github.com/rokej/BlueApplications.git
        targetRevision: main
        path: mobileApplication
      destination:
        namespace: mobileapp
        name: "argocd-agent-{{name}}"
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
        automated:
          selfHeal: true
```

3. **Principal routes the Application.** The Principal sees `destination.name: argocd-agent-blue-cluster` and streams the Application spec over the gRPC tunnel to the matching agent.
4. **Agent reconciles locally.** The agent's application controller on `blue-cluster` fetches the manifest from Git and applies it to the `mobileapp` namespace using its own ServiceAccount.
5. **Status flows back.** The agent streams sync and health status back to the Principal, which surfaces it through the hub UI and Redis proxy.
6. **RBAC filters the view.** When `bluesre1` opens the ArgoCD dashboard, the `blue-team` AppProject RBAC ensures they see `mobileapp-blue-cluster` but not the red team's `galaga` applications or the platform baseline.

### What each persona sees

| User | Group | Visible applications |
|------|-------|---------------------|
| acmsre1 | acm-sre-group | All applications across all clusters |
| bluesre1 | blue-sre-group | mobileapp-* only (blue-team project) |
| redsre1 | red-sre-group | galaga-* only (red-team project) |
| acmviewer1 | acm-viewer-group | All applications (read-only) |

## Benefits

This approach gives you one control plane for many teams without sacrificing isolation. Every action passes through a least-privilege RBAC check tied to your existing identity provider. Audit trails are centralized because all sync events flow through the Principal. And because AppProjects, groups, and ApplicationSets are all declarative YAML in Git, your tenancy model is versioned, reviewable, and reproducible. Adding a new team is a pull request, not a ticket.

## Challenges to watch for

**The dual-sync requirement** is the subtlest gotcha. If an AppProject exists on the hub but has not been streamed to a spoke, the agent's application controller rejects syncs for that project. The `destinations[].name` field controls which agents receive the project, so a misconfigured destination can silently block deployments.

**Wildcard versus tight scoping** is an ongoing tension. The demo uses `'*'` wildcards for `sourceRepos` and `destinations` for clarity, but production deployments should tighten these to specific repositories and cluster names. Wildcards are forgiving when learning; they are dangerous with real workloads.

**RBAC complexity at scale** grows faster than you expect. With 10 teams you have at least 20 groups, 10 AppProjects, and 10 sets of Casbin policies. Templating with Kustomize or Helm keeps configuration manageable, but invest in that tooling before the third team onboards.

## What is ahead

The ArgoCD community is actively working on more granular tenancy primitives, including namespace-scoped AppProjects and finer-grained resource permissions. Red Hat OpenShift GitOps continues to track these upstream improvements. As the Principal/Agent model matures, I expect tenant isolation to move closer to the agent itself, giving spoke clusters the ability to enforce project boundaries independently of the hub.

## Wrap up

Multi-tenancy at fleet scale is not about building walls — it is about making the right thing easy and the wrong thing hard. AppProjects, RBAC groups, and Placements give you the building blocks to isolate teams on a shared ArgoCD instance without losing the operational simplicity of a single control plane. If you are managing more than one team on more than one cluster, this pattern is worth adopting early.

## Get started

- Explore [Red Hat Advanced Cluster Management for Kubernetes](https://www.redhat.com/en/technologies/management/advanced-cluster-management) to see how Placements and cluster sets fit into your fleet strategy.
- Read the [Red Hat OpenShift GitOps documentation](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html) for details on AppProject configuration and RBAC policies.
- Clone the [RHACM GitOps Multi-Tenancy Demo repository](https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo) to see every YAML file referenced in this post running in a live environment.
- Read the previous post in this series for the [Principal/Agent architecture](https://www.redhat.com/en/blog) that makes fleet-wide GitOps possible.
