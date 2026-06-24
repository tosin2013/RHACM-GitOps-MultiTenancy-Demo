# Deployment Guide: Principal/Agent Fleet GitOps

> **Feature Status:** ArgoCD Agent is **Generally Available** since OpenShift GitOps 1.19 (March 2026).
> See [Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html/release_notes/gitops-release-notes) for details.

## Automated Deployment

For RHPDS environments or quick setup, use the one-command orchestrator:

```bash
bash scripts/deploy-demo.sh
```

This auto-detects your environment (base domain, Keycloak, AWS creds) and runs all steps below.
Use `--skip-clusters` if spoke clusters already exist, or `--dry-run` to preview actions.
See [RHPDS Quickstart](rhpds-quickstart.md) for environment-specific details.

---

## Version Requirements

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OpenShift GitOps | **1.19** | ArgoCD Agent GA ([Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html/release_notes/gitops-release-notes)) |
| OpenShift Container Platform | 4.14+ | Per [compatibility matrix](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html/release_notes/gitops-release-notes#compatibility-and-support-matrix) |
| RHACM | 2.15+ | Multi-cluster management |
| cert-manager Operator | Any | mTLS certificate automation |
| Subscription | OpenShift Platform Plus | Required per agent cluster |

**OCP 4.22:** The GitOps operator functions on OCP 4.22 via OLM but is not yet listed in the 1.20 support matrix. Official certification expected in a future GitOps release.

---

## Prerequisites

- 1 OpenShift hub cluster with RHACM 2.15+ installed
- OpenShift GitOps operator >= 1.19 (ArgoCD Agent GA)
- AWS credentials with permissions to create EC2 instances, VPCs, and Route53 records
- OpenShift pull secret from https://console.redhat.com/openshift/install/pull-secret
- SSH keypair for cluster node access
- `oc` CLI installed and authenticated to the hub cluster

## Step 1: Login and Verify Hub

```bash
oc login --token=<your-token> --server=https://<hub-api-endpoint>:6443

oc get multiclusterhub -A
oc get csv -n open-cluster-management | grep advanced-cluster-management
```

Expected: `multiclusterhub` status is `Running`, CSV shows `Succeeded`.

## Step 2: Create AWS Credential

```bash
oc create namespace aws-credentials --dry-run=client -o yaml | oc apply -f -

oc create secret generic aws-credentials -n aws-credentials \
  --from-literal=aws_access_key_id="<YOUR_KEY>" \
  --from-literal=aws_secret_access_key="<YOUR_SECRET>" \
  --from-file=pullSecret=~/pull-secret.json \
  --from-file=ssh-publickey=~/.ssh/id_rsa.pub \
  --from-file=ssh-privatekey=~/.ssh/id_rsa \
  --from-literal=baseDomain="<YOUR_BASE_DOMAIN>"

oc label secret aws-credentials -n aws-credentials \
  cluster.open-cluster-management.io/type=aws \
  cluster.open-cluster-management.io/credentials=""
```

## Step 3: Create ManagedClusterSets

```bash
oc apply -f - <<'EOF'
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: blueclusterset
---
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: redclusterset
EOF
```

## Step 4: Provision Spoke Clusters

Run the pre-deployment check:

```bash
bash cluster-provisioning/pre-deploy-check.sh
```

Copy secrets and provision:

```bash
for NS in blue-cluster red-cluster; do
  oc create namespace $NS --dry-run=client -o yaml | oc apply -f -
  oc create secret generic aws-credentials -n $NS \
    --from-literal=aws_access_key_id="<KEY>" \
    --from-literal=aws_secret_access_key="<SECRET>" \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic pull-secret -n $NS \
    --from-file=.dockerconfigjson=~/pull-secret.json \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic ${NS}-ssh-private-key -n $NS \
    --from-file=ssh-privatekey=~/.ssh/id_rsa \
    --dry-run=client -o yaml | oc apply -f -
done

oc apply -f cluster-provisioning/blue-cluster.yaml
oc apply -f cluster-provisioning/red-cluster.yaml
```

Monitor provisioning (~30-45 min):

```bash
watch oc get clusterdeployment -A
```

## Step 5: Deploy Users, Groups, and RBAC

```bash
oc create secret generic htpass-secret \
  --from-file=htpasswd=./UsersGroups/htpasswd -n openshift-config
oc apply -k ./UsersGroups
oc adm policy add-cluster-role-to-group cluster-admin acm-sre-group
oc adm policy add-cluster-role-to-group view acm-viewer-group
```

## Step 6: Install GitOps Operator and Deploy Principal

```bash
oc apply -k ./AcmPolicies/InstallGitOpsOperator
# Wait for openshift-gitops pods to be Running
oc get pods -n openshift-gitops -w

oc apply -k ./AcmPolicies/FleetArgoCD
oc apply -k ./AcmPolicies/RegisterAllClustersToFleet
```

## Step 7: Setup mTLS Certificates (cert-manager — Recommended)

The recommended approach uses cert-manager to automate certificate lifecycle:

```bash
bash scripts/setup-agent-tls.sh \
  --blue-kubeconfig /tmp/blue-cluster-kubeconfig \
  --red-kubeconfig /tmp/red-cluster-kubeconfig
```

This script:
1. Installs the cert-manager operator (if missing)
2. Creates a CA Issuer chain in the `fleet-gitops` namespace
3. Discovers the Principal passthrough route automatically
4. Issues server and client certificates
5. Deploys certs and Agent CRs to both spoke clusters

For more details, see [ArgoCD Agent Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/argo_cd_agent_installation/).

<details>
<summary>Alternative: Manual OpenSSL certificates (deprecated)</summary>

```bash
bash certs/generate-certs.sh
```

Create secrets on the hub:

```bash
CERT_DIR=certs/generated

oc create secret generic argocd-agent-ca -n fleet-gitops \
  --from-file=ca.crt="$CERT_DIR/ca.crt"

oc create secret tls argocd-agent-principal-tls -n fleet-gitops \
  --cert="$CERT_DIR/hub.crt" --key="$CERT_DIR/hub.key"

oc create secret tls argocd-agent-resource-proxy-tls -n fleet-gitops \
  --cert="$CERT_DIR/hub.crt" --key="$CERT_DIR/hub.key"

openssl genrsa -out /tmp/jwt.key 2048
oc create secret generic argocd-agent-jwt -n fleet-gitops \
  --from-file=jwt.key=/tmp/jwt.key
rm /tmp/jwt.key
```

> **Note:** This method requires manual certificate rotation and does not handle Agent CR deployment.
> Prefer `scripts/setup-agent-tls.sh` for production use.

</details>

Grant Principal RBAC:

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fleet-argocd-agent-principal
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications", "applicationsets", "appprojects"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps", "events"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fleet-argocd-agent-principal
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fleet-argocd-agent-principal
subjects:
  - kind: ServiceAccount
    name: fleet-argocd-agent-principal
    namespace: fleet-gitops
EOF
```

## Step 8: Deploy ApplicationSets

```bash
oc apply -k ./ApplicationSets/fleet
```

## Step 9: Configure RBAC

```bash
oc patch configmap argocd-rbac-cm -n fleet-gitops --type merge \
  -p '{"data":{"policy.csv":"g, acm-sre-group, role:admin\ng, acm-viewer-group, role:readonly\n","policy.default":"role:","scopes":"[groups]"}}'

oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:admin:blueclusterset blue-sre-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:view:blueclusterset blue-viewer-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:admin:redclusterset red-sre-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:view:redclusterset red-viewer-group
```

## Step 10: Deploy Agents (after clusters are ready)

Once spoke clusters show `AVAILABLE=True`:

```bash
oc label managedcluster blue-cluster cluster.open-cluster-management.io/clusterset=blueclusterset
oc label managedcluster red-cluster cluster.open-cluster-management.io/clusterset=redclusterset
```

Deploy Agent CRs on each spoke (requires login to each spoke cluster):

```bash
# Login to blue-cluster
oc login --server=https://api.blue-cluster.<domain>:6443
oc apply -f agents/blue-cluster-agent.yaml
oc create secret generic argocd-agent-tls -n argocd-agent-blue-cluster \
  --from-file=ca.crt=certs/generated/ca.crt \
  --from-file=tls.crt=certs/generated/blue-agent.crt \
  --from-file=tls.key=certs/generated/blue-agent.key
oc apply -f agents/network-policy.yaml

# Login to red-cluster
oc login --server=https://api.red-cluster.<domain>:6443
oc apply -f agents/red-cluster-agent.yaml
oc create secret generic argocd-agent-tls -n argocd-agent-red-cluster \
  --from-file=ca.crt=certs/generated/ca.crt \
  --from-file=tls.crt=certs/generated/red-agent.crt \
  --from-file=tls.key=certs/generated/red-agent.key
oc apply -f agents/network-policy.yaml
```

## Step 11: Validate

```bash
# Back on hub
oc login --server=https://<hub-api>:6443

oc get managedclusters
oc get pods -n fleet-gitops
oc get placementdecision -n fleet-gitops
oc get applications.argoproj.io -n fleet-gitops

# Get the Principal UI URL
oc get route fleet-argocd-server -n fleet-gitops
```

Expected: All Applications show `Synced` and `Healthy`.
