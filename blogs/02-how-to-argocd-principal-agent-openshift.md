---
title: "How to set up ArgoCD Principal/Agent architecture for fleet-scale GitOps on OpenShift"
seo_meta_title: "Set up ArgoCD Principal/Agent on OpenShift"
seo_meta_description: "Learn how to implement ArgoCD Principal/Agent architecture on OpenShift with RHACM. A step-by-step guide to mTLS, ApplicationSets, and fleet-scale GitOps."
url_slug: how-to-argocd-principal-agent-openshift
primary_keyword: "ArgoCD Principal/Agent OpenShift"
secondary_keywords: "fleet GitOps, RHACM multi-cluster, ArgoCD agent mode, mTLS ArgoCD, OpenShift GitOps scalability, ApplicationSet clusterDecisionResource"
series: "Fleet-scale GitOps with RHACM"
series_part: 2
series_total: 5
template: "How-to Article"
---

## How to set up ArgoCD Principal/Agent architecture for fleet-scale GitOps on OpenShift

If you've managed more than a handful of OpenShift clusters with a centralized ArgoCD instance, you've probably felt the ceiling. The hub becomes a bottleneck. It stores kubeconfigs for every downstream cluster. It needs outbound network access to every spoke API. And when it goes down, every cluster loses sync at once.

I hit that ceiling while building a fleet-scale GitOps platform with Red Hat Advanced Cluster Management for Kubernetes (RHACM). The answer was ArgoCD's Principal/Agent architecture, a pull-based model where each spoke cluster runs its own lightweight agent and reconciles locally. No stored credentials on the hub. No inbound firewall rules on the spokes. Independent failure domains.

In this post, I'll walk you through setting up ArgoCD Principal/Agent on OpenShift, from mTLS certificates all the way to ApplicationSets that target clusters dynamically through RHACM Placement decisions. By the end, you'll have a working architecture that scales horizontally as you add clusters to your fleet.

## Prerequisites

Before you start, make sure you have the following in place:

- **Red Hat Advanced Cluster Management for Kubernetes 2.15** installed on your hub cluster
- **One or more spoke clusters** registered as ManagedClusters in RHACM (this walkthrough uses two: `blue-cluster` and `red-cluster`)
- **Red Hat OpenShift GitOps operator** installed on the hub and all spoke clusters
- **cert-manager** (or another certificate management tool) available on the hub for generating mTLS certificates
- **oc CLI** authenticated to your hub cluster with cluster-admin privileges

## Step 1: Understand the architecture

In the traditional push model, a single ArgoCD instance on the hub runs a full application controller. It fetches manifests from Git, connects to each spoke's Kubernetes API using stored kubeconfigs, and pushes resources directly. That works fine for a few clusters, but it creates a single point of failure that gets worse with every cluster you add.

The Principal/Agent model flips this around. The **Principal** runs on the hub with the application controller *disabled*. It handles the UI, ApplicationSet controller, and a gRPC endpoint. The **Agent** runs on each spoke with the server component *disabled*. It initiates an outbound gRPC connection to the Principal over mTLS, receives Application specs, reconciles them locally using its own ServiceAccount, and streams sync status back.

Here's the data flow in practice:

1. An ApplicationSet on the hub generates Application resources based on RHACM Placement decisions.
2. The Principal detects new Applications and routes them to the correct agent based on `spec.destination.name`.
3. Each agent receives its Application specs over the gRPC tunnel, fetches manifests from Git, and applies them locally.
4. Sync status flows back through the same tunnel to the Principal, where it appears in the hub's ArgoCD UI.

The result is a single pane of glass on the hub, with all the heavy lifting distributed across your fleet.

## Step 2: Set up the mTLS certificate chain

The Principal and Agent authenticate each other using mutual TLS. You need a shared root Certificate Authority (CA), a server certificate for the Principal, and a leaf certificate for each Agent. The leaf certificate's Common Name (CN) identifies the agent, so it must match the cluster name.

If you're using cert-manager, start by creating a self-signed root CA:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: fleet-argocd-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: fleet-argocd-ca
  namespace: fleet-gitops
spec:
  isCA: true
  commonName: fleet-argocd-ca
  secretName: fleet-argocd-ca
  issuerRef:
    name: fleet-argocd-selfsigned
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: fleet-argocd-issuer
  namespace: fleet-gitops
spec:
  ca:
    secretName: fleet-argocd-ca
```

Then, for each spoke cluster, generate a leaf certificate with the CN set to the cluster name. This is critical because the Principal uses the regex `CN=([^,]+)` to extract the agent identity from the certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-blue-cluster
  namespace: fleet-gitops
spec:
  secretName: argocd-agent-blue-cluster-tls
  commonName: blue-cluster
  issuerRef:
    name: fleet-argocd-issuer
    kind: Issuer
```

You'll need to distribute the CA certificate and each leaf certificate (key pair) to the corresponding spoke cluster as Kubernetes Secrets. The CA goes into a secret named `argocd-agent-ca`, and the leaf cert goes into `argocd-agent-client-tls` in the agent's namespace.

## Step 3: Deploy the Principal ArgoCD on the hub

The Principal ArgoCD instance lives in the `fleet-gitops` namespace on the hub. The key difference from a standard ArgoCD installation is that the application controller is *disabled* and the agent principal component is *enabled*.

Here's the ArgoCD custom resource:

```yaml
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: fleet-argocd
  namespace: fleet-gitops
spec:
  controller:
    enabled: false
  argoCDAgent:
    principal:
      enabled: true
      logLevel: "info"
      auth: "mtls:CN=([^,]+)"
      tls:
        insecureGenerate: false
  sourceNamespaces:
    - "argocd-agent-blue-cluster"
    - "argocd-agent-red-cluster"
  applicationSet: {}
  sso:
    provider: dex
    dex:
      openShiftOAuth: true
  server:
    route:
      enabled: true
```

A few things to note here:

- **`controller.enabled: false`** turns off the local application controller. The Principal doesn't reconcile anything; it delegates to agents.
- **`argoCDAgent.principal.enabled: true`** activates the gRPC endpoint that agents connect to.
- **`auth: "mtls:CN=([^,]+)"`** tells the Principal to extract the agent name from the client certificate's CN field.
- **`tls.insecureGenerate: false`** means you're providing your own certificates (the ones from Step 2) instead of letting the operator generate self-signed certs.
- **`sourceNamespaces`** lists the agent namespaces so the Principal can watch Application resources created in those namespaces.
- **`server.route.enabled: true`** exposes the ArgoCD UI via an OpenShift Route. This is your single pane of glass for the entire fleet.

The SSO configuration with Dex and OpenShift OAuth is optional but recommended for integrating with your existing identity provider.

## Step 4: Deploy the Agent ArgoCD on spoke clusters

Each spoke cluster gets its own ArgoCD Agent instance. The server component is disabled (no UI, no API, no Route), and the agent connects outbound to the Principal.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd-agent-blue-cluster
---
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: agent-argocd
  namespace: argocd-agent-blue-cluster
spec:
  server:
    enabled: false
  argoCDAgent:
    agent:
      enabled: true
      client:
        principalServerAddress: "fleet-argocd-agent-principal-fleet-gitops.apps.<hub-domain>"
        principalServerPort: "443"
      tls:
        rootCASecretName: argocd-agent-ca
        secretName: argocd-agent-client-tls
```

The `principalServerAddress` follows the pattern `<argocd-name>-agent-principal-<namespace>.apps.<hub-cluster-domain>`. This is the OpenShift Route that exposes the Principal's gRPC endpoint.

The TLS configuration points to two secrets in the agent's namespace:

- **`argocd-agent-ca`** contains the root CA certificate for validating the Principal's server certificate.
- **`argocd-agent-client-tls`** contains the leaf certificate and key that the agent presents during the mTLS handshake.

For additional spoke clusters, repeat this step with a different namespace name (for example, `argocd-agent-red-cluster`) and the corresponding leaf certificate.

## Step 5: Configure routing and namespace permissions

This is where most people run into trouble. Several configuration details need to align for Applications to flow correctly from the hub to the spokes.

**Destination-based mapping** must be enabled on both sides. The Principal uses `spec.destination.name` on each Application to determine which agent should receive it. Set the environment variables `ARGOCD_PRINCIPAL_DESTINATION_BASED_MAPPING=true` on the Principal and `ARGOCD_AGENT_DESTINATION_BASED_MAPPING=true` on each Agent.

**Agent `allowedNamespaces`** controls which namespaces the agent can create Application resources in. Since Applications arrive in the `fleet-gitops` namespace on the spoke (matching the hub), the agent needs permission to operate there:

```yaml
argoCDAgent:
  agent:
    enabled: true
    allowedNamespaces:
      - "fleet-gitops"
```

**`ARGOCD_APPLICATION_NAMESPACES`** must be set on the spoke's application controller when Applications live in a different namespace than the ArgoCD instance. For example, if the agent runs in `argocd-agent-blue-cluster` but Applications land in `fleet-gitops`, the controller needs this variable to watch the correct namespace.

**Cluster secret namespaces** on the spoke must list every target namespace the application controller can deploy to. The operator manages this based on namespace labels, but you should verify that namespaces like `mobileapp` or `platform-config` are included.

**Redis proxy** is required for the hub UI to display real-time sync status. The hub ArgoCD server must be configured to use the Principal's Redis proxy service (for example, `fleet-argocd-agent-principal-redisproxy:6379`) so that status updates streamed from agents appear in the dashboard.

## Step 6: Create AppProjects and ApplicationSets

With the infrastructure in place, you can now define tenant boundaries and deploy applications across your fleet.

**AppProjects** provide RBAC isolation within the single Principal instance. Each tenant team gets their own project with scoped access. The `destinations` field must use `name: "*"` so the Principal can route Applications to any agent:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: blue-team
  namespace: fleet-gitops
spec:
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
      policies:
        - p, proj:blue-team:admin, applications, *, blue-team/*, allow
      groups:
        - blue-sre-group
```

The wildcard in `destinations[].name` is essential. The Principal uses this field to decide which agents should receive the AppProject. Without it, agents won't recognize Applications that belong to this project.

**ApplicationSets** with the `clusterDecisionResource` generator dynamically create Application resources based on RHACM Placement decisions. As clusters join or leave a PlacementDecision, the ApplicationSet controller creates or removes the corresponding Applications automatically:

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

The `{{name}}` variable comes from the PlacementDecision and resolves to the cluster name (for example, `blue-cluster`). The destination `name: "argocd-agent-{{name}}"` maps to the agent registered with that name, which is how the Principal knows where to route each Application.

## Common issues and troubleshooting

**Agent can't connect to Principal.** Verify the `principalServerAddress` matches the OpenShift Route hostname exactly. Check that the Route uses TLS passthrough termination, not edge. The gRPC connection requires end-to-end TLS.

**Applications stuck in "Unknown" status.** This usually means the Redis proxy isn't configured on the hub server. The UI can't display agent status without it.

**Agent identity mismatch.** If the Principal logs show authentication failures, verify that the leaf certificate's CN matches the agent name the Principal expects. The regex `CN=([^,]+)` must extract the exact cluster name.

**Applications not appearing on spokes.** Check that `allowedNamespaces` includes `fleet-gitops` on the agent CR, and that `ARGOCD_APPLICATION_NAMESPACES` is set on the spoke's application controller. Also verify the AppProject `destinations[].name` includes `"*"` or the specific agent name.

**Namespace creation failures.** Ensure `CreateNamespace=true` is set in the Application's `syncOptions` and that the agent's ServiceAccount has permission to create namespaces on the spoke.

## Tips and best practices

- **Automate certificate distribution with RHACM Policies.** Instead of manually copying TLS secrets to each spoke, use a ConfigurationPolicy to enforce the secrets across your fleet. This is how the demo repo handles it.
- **Use RHACM Placements for dynamic targeting.** The `clusterDecisionResource` generator integrates directly with RHACM's Placement API, so adding a new cluster to a ManagedClusterSet automatically picks it up for deployments.
- **Keep platform-baseline Applications separate.** Use a dedicated `default` AppProject for cross-cutting platform configuration (network policies, resource quotas) and team-specific projects for application workloads.
- **Set `prune: false` for platform resources.** For critical infrastructure like LimitRanges and NetworkPolicies, disable pruning so resources aren't deleted automatically if accidentally removed from Git during an incident.
- **Monitor agent connectivity from the hub.** The Principal's ArgoCD UI shows connected agents. If an agent drops off, the spoke continues reconciling its last-known state independently, but new changes won't reach it until the connection is restored.

## Wrap up

You now have a working ArgoCD Principal/Agent architecture on OpenShift, backed by RHACM for cluster lifecycle and Placement-driven application targeting. The hub provides a single pane of glass for your entire fleet without becoming a bottleneck or a credential store. Each spoke cluster reconciles independently, connected to the Principal only by an outbound gRPC tunnel secured with mTLS.

This is the architecture I use in production, and the full working configuration is available in the [RHACM-GitOps-MultiTenancy-Demo repository](https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo) on the `fleetdev` branch.

## Try it yourself

- Explore [Red Hat Advanced Cluster Management for Kubernetes](https://www.redhat.com/en/technologies/management/advanced-cluster-management) to manage your fleet at scale.
- Get started with [Red Hat OpenShift GitOps](https://www.redhat.com/en/technologies/cloud-computing/openshift/gitops) for declarative cluster configuration.
- Clone the [demo repository](https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo) and follow the setup instructions to deploy this architecture in your own environment.

*This is part 2 of the "Fleet-scale GitOps with RHACM" series. Stay tuned for the next post, where I'll cover multi-tenancy and RBAC isolation across teams sharing a single Principal instance.*
