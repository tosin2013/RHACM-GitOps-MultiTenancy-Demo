# Troubleshooting Guide

## Principal Pod CrashLoopBackOff

### Missing TLS secrets

**Symptom:** Principal pod crashes with `FATAL: Could not load resource proxy TLS configuration`

**Cause:** The Principal expects specific secrets in the `fleet-gitops` namespace.

**Fix:** Create all required secrets:

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

### Missing JWT secret

**Symptom:** `FATAL: Could not create new server instance: could not read JWT secret`

**Fix:** Generate and create the JWT signing key secret (see above).

### RBAC insufficient

**Symptom:** `applications.argoproj.io is forbidden: User "system:serviceaccount:fleet-gitops:fleet-argocd-agent-principal" cannot list resource`

**Fix:** Create the ClusterRole and ClusterRoleBinding for the Principal ServiceAccount:

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

---

## Agent Not Connecting

### Certificate CN mismatch

**Symptom:** Agent connects but is immediately rejected by Principal.

**Cause:** The leaf certificate CN doesn't match any expected agent identity.

**Fix:** Verify the certificate CN matches the cluster name:

```bash
openssl x509 -in certs/generated/blue-agent.crt -noout -subject
# Should show: subject=CN = blue-cluster
```

### Route not reachable from spoke

**Symptom:** Agent pod shows connection timeout errors.

**Fix:** Verify the Principal route is accessible:

```bash
# From spoke cluster
curl -k https://fleet-argocd-server-fleet-gitops.apps.<hub-domain>/healthz
```

Check NetworkPolicy allows egress on port 443.

### GitOps operator not installed on spoke

**Symptom:** `ArgoCD` CR cannot be created on spoke.

**Fix:** Install the OpenShift GitOps operator on the spoke cluster:

```bash
oc apply -f AcmPolicies/InstallGitOpsOperator/gitOpsInstallPolicy.yaml
```

Or install directly:

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

---

## PlacementDecision Empty

**Symptom:** `oc get placementdecision -n fleet-gitops` shows no decisions or decisions with zero clusters.

### No clusters in ClusterSet

**Fix:** Verify clusters are labeled:

```bash
oc get managedclusters --show-labels | grep clusterset
```

Label if missing:

```bash
oc label managedcluster <name> cluster.open-cluster-management.io/clusterset=blueclusterset
```

### ManagedClusterSetBinding missing

**Fix:** Verify bindings exist:

```bash
oc get managedclustersetbinding -n fleet-gitops
```

The `fleet-gitopscluster` policy should create these automatically.

### Cluster not available

**Fix:** Check cluster status:

```bash
oc get managedclusters
# AVAILABLE must be True
```

---

## ApplicationSet Not Generating Applications

### PlacementDecision has no clusters

See "PlacementDecision Empty" above.

### RBAC for ApplicationSet controller

**Symptom:** ApplicationSet controller cannot read PlacementDecisions.

**Fix:** Verify the RBAC resources exist:

```bash
oc get role fleet-gitops-appset-placementdecision -n fleet-gitops
oc get rolebinding fleet-gitops-appset-placementdecision -n fleet-gitops
```

If missing, apply:

```bash
oc apply -k ./AcmPolicies/RegisterAllClustersToFleet
```

### Wrong repoURL in ApplicationSet

**Symptom:** Applications are generated but show `ComparisonError` or cannot fetch from Git.

**Fix:** Verify the repoURL is accessible:

```bash
git ls-remote https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo.git fleetdev
```

---

## Cluster Provisioning Failures

### Elastic IP quota exceeded

**Symptom:** ClusterDeployment shows `ProvisionFailed` with EIP error.

**Fix:** Release orphaned EIPs or request a quota increase:

```bash
bash cluster-provisioning/pre-deploy-check.sh
```

### ClusterImageSet not found

**Symptom:** `imageSetRef` points to a non-existent ClusterImageSet.

**Fix:** List available sets and update the YAML:

```bash
oc get clusterimageset | grep multi-appsub | sort -V | tail -5
```

### DNS zone not delegated

**Symptom:** Cluster provisioning hangs at DNS validation step.

**Fix:** Ensure your base domain has a Route53 hosted zone and the NS records are delegated from the parent zone.

---

## Principal Shows applicationsCount=0

### Applications stuck in terminating state

**Symptom:** Principal logs show `applicationsCount=0` for all agents despite Applications existing in `fleet-gitops`.

**Root Cause:** Applications have a `deletionTimestamp` set with finalizers blocking deletion. The informer ignores terminating resources.

**Diagnosis:**
```bash
oc get applications.argoproj.io -n fleet-gitops -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.deletionTimestamp}{"\n"}{end}'
```

**Fix:** Remove finalizers from stuck apps:
```bash
for app in $(oc get applications.argoproj.io -n fleet-gitops -o jsonpath='{.items[*].metadata.name}'); do
  oc patch application.argoproj.io $app -n fleet-gitops --type merge -p '{"metadata":{"finalizers":null}}'
done
```

### AppProject missing `destinations[].name` field

**Symptom:** Principal trace logs show apps added to send queue but `mapAppProjectToAgents` returns empty (no "Added appProject to send queue" messages).

**Root Cause:** For destination-based mapping, AppProjects must have a `name` field in their `destinations` that matches agent names.

**Fix:**
```bash
oc patch appproject default -n fleet-gitops --type merge \
  -p '{"spec":{"destinations":[{"namespace":"*","server":"*","name":"*"}]}}'
```

### Agent rejects apps: "namespace not in allowed namespaces list"

**Symptom:** Agent logs show `Error creating application: namespace fleet-gitops is not permitted: not in allowed namespaces list`

**Root Cause:** The agent doesn't have `fleet-gitops` in its allowed namespaces. In destination-based mapping, the agent creates apps in the same namespace as the Principal.

**Fix:**
```bash
oc patch argocd agent-argocd -n argocd-agent-<name> --type merge \
  -p '{"spec":{"argoCDAgent":{"agent":{"allowedNamespaces":["fleet-gitops"]}}}}'
```

### Spoke app-controller: "namespace X is not managed"

**Symptom:** Apps on spoke show `Unknown` sync status with condition `Failed to load live state: namespace "X" is not managed`.

**Root Cause:** The cluster secret's `namespaces` field restricts which namespaces ArgoCD can manage.

**Fix:** Add target namespaces to the cluster secret:
```bash
KUBECONFIG=/tmp/<cluster>-kubeconfig oc patch secret agent-argocd-default-cluster-config \
  -n argocd-agent-<name> --type merge \
  -p '{"stringData":{"namespaces":"argocd-agent-<name>,fleet-gitops,<target-ns-1>,<target-ns-2>"}}'
```

Also label the target namespaces:
```bash
oc label namespace <target-ns> argocd.argoproj.io/managed-by=agent-argocd
```

### Spoke app-controller: "cannot list applications at cluster scope"

**Symptom:** Controller logs show RBAC forbidden errors for listing Applications cluster-wide.

**Root Cause:** When `ARGOCD_APPLICATION_NAMESPACES` is set, the controller attempts a cluster-wide list/watch.

**Fix:**
```bash
KUBECONFIG=/tmp/<cluster>-kubeconfig oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:argocd-agent-<name>:agent-argocd-argocd-application-controller
```

---

## ACM Policy NonCompliant

### Check policy details

```bash
oc get policy -n acm-gitops-policy
oc get configurationpolicy <name> -n local-cluster -o yaml | grep -A 20 "status:"
```

### API version mismatch

**Symptom:** Policy error mentions `strict decoding error: unknown field`

**Fix:** Ensure ArgoCD CR uses `argoproj.io/v1beta1` API version. In v1beta1, `dex` is nested under `sso.dex`:

```yaml
spec:
  sso:
    provider: dex
    dex:
      openShiftOAuth: true
```

Not the old v1alpha1 format:

```yaml
# WRONG for v1beta1:
spec:
  dex:
    openShiftOAuth: true
```
