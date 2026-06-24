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

## Manual Deployment Steps

The steps below mirror what `scripts/deploy-demo.sh` does automatically.
They are organized into three phases:

```
Phase A: Hub Setup (Steps 1-4)     — can start immediately
Phase B: Spoke Clusters (Steps 5-6) — requires AWS quota validation
Phase C: Agent + Apps (Steps 7-9)   — requires spoke clusters to be ready
```

---

### Step 1: Login and Verify Hub

```bash
oc login --token=<your-token> --server=https://<hub-api-endpoint>:6443

oc get multiclusterhub -A
oc get csv -n open-cluster-management | grep advanced-cluster-management
```

Expected: `multiclusterhub` status is `Running`, CSV shows `Succeeded`.

### Step 2: Deploy Users and Auth

The `setup-users.sh` script auto-detects Keycloak or falls back to htpasswd:

```bash
bash scripts/setup-users.sh --password 'YourPassword'
```

See [User Management](user-management.md) for details on Keycloak vs htpasswd modes.

### Step 3: Install GitOps Operator and Deploy Principal

```bash
oc apply -k ./AcmPolicies/InstallGitOpsOperator

# Wait for GitOps operator (~2 minutes)
oc get csv -n openshift-gitops -w

oc apply -k ./AcmPolicies/FleetArgoCD
oc apply -k ./AcmPolicies/RegisterAllClustersToFleet
```

Verify the Principal is running:

```bash
oc get pods -n fleet-gitops -l app.kubernetes.io/part-of=argocd
```

### Step 4: Create AWS Credential and ManagedClusterSets

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

---

### Step 5: Pre-Deployment Check (IMPORTANT)

Before provisioning spoke clusters, validate that your AWS account can support them.
The `pre-deploy-check.sh` script validates:

- **Elastic IP quota** — Each SNO cluster needs 3 EIPs (one per AZ for NAT gateways). Two clusters = 6 EIPs minimum.
- **vCPU quota** — Each `m6i.2xlarge` needs 8 vCPUs (16 total for both clusters).
- **Orphaned resources** — Releases unassociated EIPs from previous failed deployments.
- **ClusterImageSet** — Confirms the required OCP image version exists on the hub.
- **AWS CLI** — Installs the AWS CLI if missing (reads credentials from the ACM secret).

```bash
bash cluster-provisioning/pre-deploy-check.sh
```

**If the script reports NOT READY**, address the issues before proceeding:

| Issue | Resolution |
|-------|-----------|
| EIP quota too low | Script offers to request a quota increase (auto-approved in ~5 min) |
| Orphaned EIPs | Script offers to release unassociated EIPs |
| ClusterImageSet missing | Create one: `oc apply -f cluster-provisioning/clusterimageset.yaml` |
| vCPU quota too low | Request increase via AWS console (may take hours) |

### Step 6: Provision Spoke Clusters

**Option A: Use templates (recommended for fresh environments):**

If your base domain differs from what's in the YAML files, generate from templates:

```bash
export BASE_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')
export SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
export CLUSTER_IMAGE_SET="img4.21.20-multi-appsub"  # adjust to available version

envsubst < cluster-provisioning/blue-cluster.yaml.tpl > /tmp/blue-cluster.yaml
envsubst < cluster-provisioning/red-cluster.yaml.tpl > /tmp/red-cluster.yaml
```

**Option B: Use existing YAMLs (if base domain already matches):**

```bash
# Skip envsubst, use files directly
```

**Prepare namespaces and deploy:**

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

# Apply (use /tmp/ files if generated from templates, or repo files directly)
oc apply -f cluster-provisioning/blue-cluster.yaml
oc apply -f cluster-provisioning/red-cluster.yaml
```

**Monitor provisioning** (~30-45 minutes for SNO clusters):

```bash
watch oc get clusterdeployment -A
# Or check ManagedCluster status:
watch oc get managedcluster
```

Wait until both clusters show `AVAILABLE=True` before proceeding to Step 7.

---

### Step 7: Setup mTLS and Deploy Agents

Once both spoke clusters are `AVAILABLE=True`, extract their kubeconfigs and run the TLS setup:

```bash
# Extract kubeconfigs from Hive secrets
BLUE_SECRET=$(oc get clusterdeployment blue-cluster -n blue-cluster \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')
RED_SECRET=$(oc get clusterdeployment red-cluster -n red-cluster \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')

oc get secret "$BLUE_SECRET" -n blue-cluster -o jsonpath='{.data.kubeconfig}' \
  | base64 -d > /tmp/blue-cluster-kubeconfig
oc get secret "$RED_SECRET" -n red-cluster -o jsonpath='{.data.kubeconfig}' \
  | base64 -d > /tmp/red-cluster-kubeconfig

# Run the TLS + Agent deployment script
bash scripts/setup-agent-tls.sh \
  --blue-kubeconfig /tmp/blue-cluster-kubeconfig \
  --red-kubeconfig /tmp/red-cluster-kubeconfig
```

This single script handles everything:
1. Installs cert-manager operator on the hub (if missing)
2. Creates a CA Issuer chain in `fleet-gitops`
3. Discovers the Principal passthrough route automatically
4. Issues server certificate for the Principal
5. Issues client certificates for each agent (CN=blue-cluster, CN=red-cluster)
6. Deploys TLS secrets to spoke clusters
7. Creates the ArgoCD Agent CRs on each spoke cluster
8. Grants necessary RBAC on spoke clusters

For more details, see [ArgoCD Agent Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/argo_cd_agent_installation/).

<details>
<summary>Alternative: Manual OpenSSL certificates (deprecated)</summary>

If cert-manager is unavailable, you can generate static certificates:

```bash
bash certs/generate-certs.sh
```

Then manually create secrets and deploy agents per the instructions in `certs/generate-certs.sh` output.
This method requires manual certificate rotation and separate Agent CR deployment.

</details>

### Step 8: Deploy ApplicationSets and Configure RBAC

```bash
# ApplicationSets (generates Applications per placement)
oc apply -k ./ApplicationSets/fleet

# ArgoCD RBAC (maps OpenShift groups to ArgoCD roles)
oc patch configmap argocd-rbac-cm -n fleet-gitops --type merge \
  -p '{"data":{"policy.csv":"g, acm-sre-group, role:admin\ng, acm-viewer-group, role:readonly\n","policy.default":"role:","scopes":"[groups]"}}'

# ACM ManagedClusterSet RBAC (per-team cluster access)
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:admin:blueclusterset blue-sre-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:view:blueclusterset blue-viewer-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:admin:redclusterset red-sre-group
oc adm policy add-cluster-role-to-group open-cluster-management:managedclusterset:view:redclusterset red-viewer-group
```

### Step 9: Validate

```bash
# Check managed clusters
oc get managedclusters
# Expected: blue-cluster and red-cluster show AVAILABLE=True

# Check Principal pods
oc get pods -n fleet-gitops
# Expected: All pods Running

# Check applications are synced
oc get applications.argoproj.io -n fleet-gitops
# Expected: All show Synced/Healthy

# Get the ArgoCD UI URL
oc get route fleet-argocd-server -n fleet-gitops -o jsonpath='{.spec.host}'
```

Login to the ArgoCD UI with `admin` and the password from:

```bash
oc get secret fleet-argocd-cluster -n fleet-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d
```

Expected: All Applications show `Synced` and `Healthy` across both spoke clusters.
