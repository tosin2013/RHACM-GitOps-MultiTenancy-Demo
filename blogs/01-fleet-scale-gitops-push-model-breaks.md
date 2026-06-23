---
title: "Fleet-scale GitOps with RHACM: Why the push model breaks at scale"
seo_meta_title: "Fleet-scale GitOps: Why the push model breaks at scale"
seo_meta_description: "Learn why centralized push-based GitOps creates bottlenecks, credential sprawl, and single points of failure at fleet scale, and what to do about it."
url_slug: /blog/fleet-scale-gitops-push-model-breaks-at-scale
primary_keyword: fleet-scale GitOps
secondary_keywords:
  - ArgoCD push model
  - multi-cluster GitOps
  - RHACM GitOps
  - centralized ArgoCD scaling
  - GitOps credential management
  - OpenShift fleet management
series: "Fleet-scale GitOps with RHACM"
series_position: 1 of 5
template: Thought Leadership
word_count_target: 800–1,300
---

I started managing five OpenShift clusters with a single ArgoCD instance and it worked great — until it didn't.

By cluster fifteen, sync times were creeping up. By cluster thirty, I was firefighting credential rotations every other week. By the time we hit fifty clusters, I had to admit that the architecture I had chosen was the problem.

This is the first post in a five-part series called **Fleet-scale GitOps with RHACM**. Over the course of the series, I will walk through the real architectural decisions — and mistakes — I encountered while scaling GitOps across a fleet of OpenShift clusters using Red Hat Advanced Cluster Management for Kubernetes (RHACM) and Red Hat OpenShift GitOps. In this post, I will explain why the push model that gets most teams started eventually becomes the thing holding them back.

If you are managing more than a handful of clusters today — or planning to — this series will give you a concrete migration path from centralized push to a decentralized, pull-based architecture that actually scales.

## The push model is today's default

Most teams start their multi-cluster GitOps journey the same way I did: one centralized ArgoCD instance on a hub cluster, pushing manifests to downstream clusters through stored kubeconfigs. It is the path of least resistance. Every tutorial teaches it. The tooling supports it out of the box.

The setup looks something like this. You register each spoke cluster as an ArgoCD cluster secret, store its kubeconfig on the hub, and create an ApplicationSet that iterates over all of them:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-baseline
  namespace: openshift-gitops
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            environment: production
  template:
    metadata:
      name: platform-baseline-{{name}}
    spec:
      project: default
      source:
        repoURL: https://github.com/my-org/platform-config.git
        targetRevision: main
        path: baseline
      destination:
        namespace: platform-config
        server: "{{server}}"
      syncPolicy:
        automated:
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

This is clean, declarative, and easy to reason about. The hub's application controller reads this ApplicationSet, generates one Application custom resource (CR) per matching cluster, and pushes the desired state to each spoke using the stored kubeconfig. RHACM makes this even smoother by integrating Placements and ManagedClusterSets, so you can target clusters by label rather than managing secrets by hand.

The industry is moving fast here. Organizations that managed ten clusters two years ago are now managing fifty, a hundred, or more. Edge computing, regulated workloads, and multi-cloud strategies are all driving fleet sizes up. The push model that worked at five clusters does not automatically work at fifty.

## What the push model gets right

Before I explain where this breaks down, I want to be fair: the push model earns its popularity for good reasons.

**Single pane of glass.** One ArgoCD dashboard shows every application across every cluster. You can see sync status, health, and drift in one place. That visibility is genuinely valuable when you are responsible for fleet-wide consistency.

**Familiar operations model.** If your team already knows ArgoCD, adding clusters to a centralized instance is the smallest possible learning curve. You are extending a pattern you already understand rather than adopting a new one.

**ApplicationSets plus RHACM Placements.** The combination is powerful. You define a Placement that selects clusters by labels and regions, and the ApplicationSet controller generates the right Applications automatically. When a new cluster joins the ManagedClusterSet, it gets its applications without anyone writing additional YAML.

**Fast time-to-value.** You can go from zero to multi-cluster GitOps in an afternoon. For teams managing fewer than fifteen or twenty clusters, this model works well and the trade-offs are manageable.

I used this model successfully for months. The problems only became visible as the fleet grew.

## Where the push model breaks down

At scale, the push model introduces four failure modes that compound each other.

### The hub becomes a bottleneck

A single ArgoCD application controller on the hub is responsible for reconciling every application on every cluster. That means one controller is doing Git fetches, computing diffs, and applying manifests across your entire fleet. As you add clusters and applications, sync latency increases linearly. I watched average sync times climb from seconds to minutes, and during peak reconciliation windows, some applications would not sync for over ten minutes.

You can tune controller concurrency and shard by cluster, but you are still working within the constraints of a single control plane. The architecture puts a ceiling on how far you can scale.

### Credential sprawl creates a lateral movement path

Every spoke cluster requires a kubeconfig stored as a Secret on the hub. That kubeconfig typically carries cluster-admin privileges because the application controller needs broad permissions to create namespaces and apply arbitrary manifests.

At thirty clusters, you have thirty sets of cluster-admin credentials sitting in one namespace. If an attacker compromises the hub, they gain access to every cluster in your fleet. Rotating those credentials is manual, error-prone, and usually deferred — which only makes the risk worse over time.

### Hub failure means fleet-wide outage

When the hub goes down, no cluster receives updates. Existing workloads keep running, but drift goes undetected, new deployments stop, and your entire GitOps pipeline is frozen. The hub is a single point of failure for your entire fleet.

I experienced this firsthand during a hub upgrade. A misconfigured resource limit caused the application controller to crash-loop for forty minutes. During that window, a configuration change that had already been merged to Git did not reach any spoke cluster. We only discovered the gap hours later.

### Network assumptions do not hold at edge

The push model requires the hub to initiate outbound connections to every spoke cluster's Kubernetes application programming interface (API). This works when all clusters sit in the same network or virtual private cloud (VPC), but it falls apart at the edge. Clusters behind firewalls, network address translation (NAT) gateways, or in restricted networks cannot be reached by the hub without complex network workarounds.

For edge deployments, this single requirement can be a dealbreaker.

## The shift to pull-based, agent-driven architectures

The ArgoCD community recognized these limitations and introduced the Principal/Agent model. Instead of the hub pushing to spokes, each spoke runs a lightweight ArgoCD Agent that initiates an outbound gRPC connection to a Principal on the hub. The Agent pulls Application specs, reconciles them locally, and streams status back.

This inverts the credential model — the hub stores zero spoke kubeconfigs — and eliminates the hub bottleneck because reconciliation happens on each spoke independently. RHACM layers fleet management on top: Placements, governance policies, and a single-pane-of-glass UI, all without the hub needing direct access to spoke APIs.

I will go deep into this architecture in Post 2.

## What to do right now

You do not need to migrate overnight, but you can start preparing today.

- **Audit your kubeconfigs.** Count how many cluster-admin credentials your hub stores. Map out who has access to that namespace and when those credentials were last rotated.
- **Measure sync latency.** Track how long it takes for a Git commit to reach each spoke cluster. If you see latency climbing or inconsistency across clusters, the hub is becoming a bottleneck.
- **Evaluate your network topology.** Identify any spoke clusters that require VPN tunnels, firewall exceptions, or bastion hosts for the hub to reach them. These are your strongest candidates for a pull-based model.
- **Plan your migration path.** You do not have to move everything at once. Start with a single non-production cluster, deploy an ArgoCD Agent, and validate the workflow before scaling out.

## Wrap up

The push model is a great starting point for multi-cluster GitOps. It is simple, familiar, and well-supported. But as your fleet grows, the centralized hub becomes a bottleneck, a credential liability, and a single point of failure that can take down your entire GitOps pipeline.

The good news is that the path forward is clear. Pull-based, agent-driven architectures eliminate these failure modes while preserving the single pane of glass that makes centralized GitOps valuable in the first place.

In the next post, I will walk through the Principal/Agent architecture in detail — how it works, how to set it up with RHACM, and what changes in your day-to-day operations.

## Call to action

If you are running centralized ArgoCD across multiple clusters today, start by auditing your hub's stored credentials and measuring your sync latency. Those two data points will tell you how urgently you need to evolve your architecture.

Explore [Red Hat Advanced Cluster Management for Kubernetes](https://www.redhat.com/en/technologies/management/advanced-cluster-management) and [Red Hat OpenShift GitOps](https://www.redhat.com/en/technologies/cloud-computing/openshift/gitops) to see how they work together for fleet-scale management.

## Learn more

- [Red Hat Advanced Cluster Management for Kubernetes documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)
- [Red Hat OpenShift GitOps documentation](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)
- [GitOps principles — CNCF OpenGitOps](https://opengitops.dev/)
