---
title: "Securing multi-cluster GitOps with mTLS and cert-manager"
series: "Fleet-scale GitOps with RHACM"
series_position: 3 of 5
template: Technical Deep Dive
seo_meta_title: "Secure multi-cluster GitOps with mTLS and cert-manager"
seo_meta_description: "Learn how mutual TLS and cert-manager create a zero-trust security model for ArgoCD Principal/Agent communication across OpenShift clusters."
url_slug: /blog/securing-multi-cluster-gitops-mtls-cert-manager
primary_keyword: multi-cluster GitOps mTLS
secondary_keywords: cert-manager OpenShift, ArgoCD Principal Agent security, zero-trust Kubernetes, mTLS certificate rotation, RHACM GitOps
---

## Securing multi-cluster GitOps with mTLS and cert-manager

*This is Part 3 of the "Fleet-scale GitOps with RHACM" series. In [Part 2](/blog/principal-agent-architecture-fleet-gitops), I walked through the Principal/Agent architecture that lets spoke clusters pull their own workloads. Now I need to answer the question my security team asked before anything else: "How does the Principal know which agent it's talking to?"*

The answer is mutual TLS (mTLS). Every ArgoCD Agent presents a client certificate signed by a shared certificate authority, and the Principal verifies it before streaming a single Application spec. No passwords, no stored kubeconfigs, no shared tokens. In this post, I'll walk through the trust chain, the cert-manager resources that automate it, and the lessons I've learned running this in production.

## Why stored kubeconfigs don't scale

In a traditional push-model GitOps setup, the hub cluster stores a kubeconfig for every spoke — making it both a credential vault and a single point of compromise. Rotate one spoke's credentials and you need to update the hub. Lose the hub and an attacker has keys to every cluster in your fleet.

mTLS eliminates that problem. Instead of the hub holding credentials to reach out, each spoke agent initiates the connection and proves its identity with a certificate. The hub proves its identity right back. Neither side trusts the other by default — they both present certificates signed by the same root certificate authority (CA) and verify them during the TLS handshake.

The trust chain I use has three levels:

1. **Root CA** — A self-signed certificate authority that anchors the entire chain
2. **Hub (server) certificate** — Presented by the Principal's gRPC endpoint, signed by the root CA
3. **Agent (leaf) certificates** — One per spoke cluster, each with a Common Name (CN) that matches the cluster's name (e.g., `CN=blue-cluster`)

This means I can onboard a new cluster by issuing a single leaf certificate — no hub credential changes, no inbound firewall rules on spokes.

## Core components

### Trust chain architecture

Every certificate traces back to the root CA. The hub's server certificate lets agents confirm they're connecting to the real Principal. Each agent's leaf certificate carries the cluster name as its CN, which the Principal uses to map connections to managed clusters.

This CN convention is critical. When an agent connects, the Principal extracts the identity using a regex pattern on the ArgoCD custom resource:

```yaml
spec:
  argoCDAgent:
    principal:
      enabled: true
      auth: "mtls:CN=([^,]+)"
      tls:
        insecureGenerate: false
```

That line tells the Principal to parse the client certificate's subject, pull the CN value, and use it as the agent's identity. When `blue-cluster` connects, the Principal knows exactly which Applications to stream.

### cert-manager resources

I use cert-manager to automate the entire certificate lifecycle. Here's the full resource chain, from root CA down to individual agent certificates.

First, a self-signed ClusterIssuer bootstraps the root:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

Next, the root CA Certificate itself. This is a long-lived certificate that anchors the trust chain:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-root-ca
  namespace: fleet-gitops
spec:
  isCA: true
  commonName: argocd-agent-ca
  secretName: argocd-agent-root-ca
  duration: 87600h  # 10 years
  renewBefore: 720h  # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
```

A namespace-scoped Issuer references that CA secret so it can sign downstream certificates:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: argocd-agent-ca-issuer
  namespace: fleet-gitops
spec:
  ca:
    secretName: argocd-agent-root-ca
```

The hub's server certificate is signed by this Issuer with the `server auth` usage:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: fleet-argocd-principal-cert
  namespace: fleet-gitops
spec:
  commonName: fleet-argocd-agent-principal
  secretName: fleet-argocd-principal-tls
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
  dnsNames:
    - fleet-argocd-agent-principal
    - fleet-argocd-agent-principal.fleet-gitops.svc
    - fleet-argocd-agent-principal-fleet-gitops.apps.<cluster-domain>
  issuerRef:
    name: argocd-agent-ca-issuer
    kind: Issuer
```

Finally, each agent gets a leaf certificate with `client auth` usage and a CN matching the cluster name:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: blue-cluster-agent-cert
  namespace: fleet-gitops
spec:
  commonName: blue-cluster
  secretName: blue-cluster-agent-tls
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - client auth
  issuerRef:
    name: argocd-agent-ca-issuer
    kind: Issuer
```

Repeat that last resource for each spoke (e.g., `red-cluster-agent-cert` with `commonName: red-cluster`).

### Secrets topology

Knowing what lives where is key for troubleshooting. On the **hub cluster** in the `fleet-gitops` namespace, cert-manager creates:

- `argocd-agent-root-ca` — The root CA key pair and certificate
- `fleet-argocd-principal-tls` — The Principal's server certificate and key
- `blue-cluster-agent-tls` — The blue agent's client certificate and key
- `red-cluster-agent-tls` — The red agent's client certificate and key

On each **spoke cluster**, in the `argocd-agent-<name>` namespace, you need two secrets:

- `argocd-agent-ca` — Contains only the root CA's `ca.crt` (the public certificate, not the key)
- `argocd-agent-client-tls` — Contains the agent's `tls.crt` and `tls.key`

The agent's ArgoCD CR references these directly:

```yaml
spec:
  argoCDAgent:
    agent:
      enabled: true
      client:
        principalServerAddress: "fleet-argocd-agent-principal-fleet-gitops.apps.<cluster-domain>"
        principalServerPort: "443"
      tls:
        rootCASecretName: argocd-agent-ca
        secretName: argocd-agent-client-tls
```

I generate certificates on the hub and distribute the leaf cert and CA bundle to each spoke using Red Hat Advanced Cluster Management for Kubernetes (RHACM) policies.

## The mTLS handshake in action

When an agent starts up, here's what happens step by step:

1. The agent reads its client certificate from `argocd-agent-client-tls` and the CA bundle from `argocd-agent-ca`.
2. It initiates an outbound gRPC connection on port 443 to the Principal's route.
3. The OpenShift route (configured as **passthrough**) forwards the raw TLS connection to the Principal pod.
4. The Principal presents its server certificate. The agent verifies it against the CA bundle — confirming it's talking to the real Principal.
5. The agent presents its client certificate. The Principal verifies it against the same root CA — confirming the agent is legitimate.
6. The Principal extracts the CN from the client certificate using the `mtls:CN=([^,]+)` regex, identifies the agent as `blue-cluster`, and begins streaming the appropriate Application specs.

Both sides are now authenticated. No passwords were exchanged, no tokens were stored, and the spoke never exposed an inbound port.

## Best practices

After running this setup across multiple environments, here's what I recommend:

- **Use ECDSA P-256 keys.** They're faster to generate and validate than RSA, with equivalent security at smaller key sizes.
- **Set `renewBefore` generously.** I use 30 days (`720h`), giving cert-manager plenty of time to renew even if a cluster is temporarily unavailable.
- **Use passthrough routes, not reencrypt.** The Principal needs the raw client certificate. Reencrypt terminates TLS at the router and breaks the handshake.
- **Stagger durations.** Root CA at 10 years, leaf certs at 1 year. This avoids everything expiring at once.
- **Monitor certificate expiry.** Use `cmctl status certificate` or Prometheus metrics from cert-manager to alert before certificates expire without renewal.

## Common challenges

**Stale CA bundle on the spoke.** If you rotate the root CA but forget to update the `argocd-agent-ca` secret on the spoke, the agent will reject the Principal's new server certificate. Automate CA distribution through RHACM policies to avoid this.

**Reencrypt route instead of passthrough.** Reencrypt terminates TLS at the OpenShift router and re-establishes a new session to the pod, stripping the client certificate. The fix: set the route to passthrough.

**CN mismatch.** If the agent's certificate CN doesn't match what the Principal expects, the connection succeeds but Applications won't route. Double-check CN values against `spec.destination.name` in your ApplicationSets.

**Certificate not ready.** The Certificate resource exists but the Secret doesn't appear. Check cert-manager controller logs and verify the Issuer is healthy with `cmctl check api`.

## Where this fits in practice

The [demo repository](https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo) accompanying this series runs a two-cluster setup: a hub with the Principal and two spokes (`blue-cluster` and `red-cluster`). The full cert-manager chain deploys on the hub, and RHACM policies distribute the leaf certs to each spoke.

This pattern scales to 50 or more clusters. The only resource that grows linearly is the number of Certificate resources on the hub — one per spoke. cert-manager handles renewal automatically, so operational overhead stays flat.

For regulated environments (PCI-DSS, HIPAA, FedRAMP), mTLS provides auditable, cryptographic identity for every cluster-to-cluster connection — fully declarative and version-controlled in Git. In air-gapped environments, the self-signed CA model works particularly well because there's no dependency on an external certificate provider.

## Wrap up

Mutual TLS gives you a zero-trust foundation for multi-cluster GitOps that scales without accumulating credential debt. cert-manager automates the lifecycle, and the ArgoCD Principal/Agent model uses CN to map connections to cluster identities cleanly.

In the next post, I'll cover how ApplicationSets and RHACM Placements target workloads to the right clusters — building on this secure layer.

## Get started

- **Try it yourself:** Clone the [RHACM GitOps MultiTenancy Demo](https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo) and follow the setup guide to deploy the full mTLS chain.
- **Learn more about RHACM:** [Red Hat Advanced Cluster Management for Kubernetes documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.15)
- **Explore OpenShift GitOps:** [Red Hat OpenShift GitOps documentation](https://docs.openshift.com/gitops/latest/understanding_openshift_gitops/about-redhat-openshift-gitops.html)
- **cert-manager on OpenShift:** [cert-manager Operator for Red Hat OpenShift](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
