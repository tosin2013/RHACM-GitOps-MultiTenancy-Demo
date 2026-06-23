---
title: "7 lessons from debugging a distributed ArgoCD principal/agent deployment"
seo_meta_title: "7 lessons debugging ArgoCD principal/agent deployment"
seo_meta_description: "Save hours of troubleshooting. These 7 hard-won lessons from a real ArgoCD principal/agent rollout expose the failure modes that docs don't warn you about."
url_slug: /blog/7-lessons-debugging-argocd-principal-agent-deployment
primary_keyword: ArgoCD principal/agent debugging
secondary_keywords:
  - OpenShift GitOps operator
  - RHACM multi-cluster GitOps
  - ArgoCD fleet management
  - distributed ArgoCD troubleshooting
series: "Fleet-scale GitOps with RHACM (Post 5 of 5)"
template: Listicle
word_count_target: 600–800
---

I spent a week watching a principal controller report zero applications while `oc get` showed a dozen sitting right there. No errors in the logs. No failed pods. Just an ArgoCD principal happily reporting an empty fleet while applications piled up, unreconciled and invisible.

The ArgoCD principal/agent model — where a hub controller delegates reconciliation to lightweight agents on spoke clusters — is a powerful architecture for fleet-scale GitOps with Red Hat Advanced Cluster Management for Kubernetes (RHACM). But when it fails, it fails silently. Every lesson below came from a real failure that produced no obvious error message.

## Lesson 1: The operator always wins

My first instinct when something broke was to patch the configmap directly. It worked — for about 90 seconds, until the OpenShift GitOps Operator quietly reverted my change on the next reconciliation cycle.

```yaml
# This gets reverted by the operator:
oc patch configmap argocd-cmd-params-cm -n fleet-gitops \
  --type merge -p '{"data":{"controller.log.level":"trace"}}'

# Right way — configure via ArgoCD CR:
spec:
  argoCDAgent:
    principal:
      logLevel: trace
```

Every configuration change has to go through the ArgoCD custom resource. The operator owns those configmaps and will overwrite anything you set directly.

## Lesson 2: The topology guardrail

The principal controller silently drops events from applications created in its own operating namespace. If your ApplicationSet generates apps in `fleet-gitops` and the principal also lives in `fleet-gitops`, the informer sees them — but the routing logic discards them as "local" applications not meant for agents.

This behavior is undocumented. I only found it by reading the source. The fix is to make sure `allowedNamespaces` is configured correctly in the ArgoCD CR so the principal watches the right namespaces and routes events instead of ignoring them.

## Lesson 3: Stuck finalizers are invisible killers

Applications with a `deletionTimestamp` set but unresolved finalizers are effectively invisible. They still exist in etcd, they show up in `oc get`, but informers treat them as "being deleted" and skip them during event processing.

I had three applications in this zombie state. They blocked new applications with the same name from being created, and they never appeared in the ArgoCD UI. The fix was to manually remove the finalizers with `oc edit`, but the real lesson is to check for stuck `deletionTimestamp` fields early in any debugging session.

## Lesson 4: AppProject destinations need the name field

This one was maddening. My AppProject looked correct — destinations allowed all namespaces and all servers. But the principal still refused to route applications to agents.

```yaml
# Broken — no name field, routing fails silently:
destinations:
  - namespace: '*'
    server: '*'

# Working — name field enables destination-based mapping:
destinations:
  - namespace: '*'
    server: '*'
    name: '*'
```

When `destinationBasedMapping` is enabled, the principal uses `spec.destination.name` to match applications to agents. Without `name: "*"` in the AppProject destinations, that matching silently fails — no error, no log entry, just applications that never arrive on the spoke.

## Lesson 5: The cluster secret namespace restriction

I assumed the `managed-by` label on namespaces was the enforcement mechanism for where agents could deploy. It isn't. The real enforcement point is the `namespaces` field in the cluster secret on each spoke.

```yaml
# The namespaces field is the real enforcement point:
apiVersion: v1
kind: Secret
metadata:
  name: agent-argocd-default-cluster-config
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  namespaces: "argocd-agent-blue-cluster,fleet-gitops,mobileapp,platform-config"
```

If a target namespace isn't listed in that comma-separated `namespaces` field, the application controller on the spoke refuses to sync there — regardless of what labels or RBAC you've configured. The `managed-by` label is used by the operator to *populate* this field, but the secret is what the controller reads at runtime.

## Lesson 6: Trace logging reveals what info logging hides

The default `info` log level for the principal controller is almost useless for debugging routing problems. Critical details about *why* an application was routed (or not routed) to a specific agent only appear at `trace` level.

Once I switched to trace logging through the ArgoCD CR (see lesson 1), I could finally see the principal's decision-making process: which agent it matched, which destination field it read, and why it skipped certain applications. This alone cut my debugging time from hours to minutes.

## Lesson 7: AppProjects must exist on both hub and spoke

I created my `blue-team` AppProject on the hub and assumed the agent would handle the rest. It didn't. The application controller on the spoke validates incoming applications against *its own local* AppProject definitions. No matching project on the spoke means a silent rejection.

Both the principal (hub) and the agent (spoke) need a copy of every AppProject that governs applications flowing through them. I ended up using RHACM policies to enforce AppProject consistency across clusters, which also solved the drift problem.

## Wrapping up

Distributed ArgoCD fails silently. That's the unifying theme across all seven of these lessons. No error banners, no failed pods, no alerts — just applications that don't arrive, don't sync, or don't appear.

These seven lessons form a diagnostic checklist I now run through every time something goes wrong with a principal/agent deployment. Start with the cluster secret namespace list, check for stuck finalizers, verify AppProject destinations include the `name` field, and turn on trace logging before you do anything else. I hope this saves you the week I lost figuring it out the hard way.

## Try it yourself

- Explore [Red Hat Advanced Cluster Management for Kubernetes](https://www.redhat.com/en/technologies/management/advanced-cluster-management) to see how RHACM simplifies multi-cluster GitOps at scale.
- Read the rest of the "Fleet-scale GitOps with RHACM" series for the full architecture walkthrough, from push model to principal/agent.
- Get started with [Red Hat OpenShift GitOps](https://www.redhat.com/en/technologies/cloud-computing/openshift/gitops) to bring ArgoCD-based delivery to your clusters.
