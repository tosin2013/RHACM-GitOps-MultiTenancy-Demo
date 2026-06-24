#!/usr/bin/env bash
set -euo pipefail

# Setup ArgoCD Principal/Agent mTLS using cert-manager
# This script handles the full TLS trust chain between the hub's ArgoCD Principal
# and the spoke cluster ArgoCD Agents.
#
# Prerequisites:
#   - oc CLI logged into the hub cluster
#   - kubeconfigs for spoke clusters available
#   - cert-manager operator installed on hub (this script will install if missing)
#
# Usage:
#   ./setup-agent-tls.sh [--blue-kubeconfig PATH] [--red-kubeconfig PATH]

# Cross-platform base64 decode (macOS uses -D, Linux uses -d)
b64decode() {
  case "$(uname -s)" in
    Darwin) base64 -D ;;
    *)      base64 -d ;;
  esac
}

PRINCIPAL_NS="${PRINCIPAL_NS:-fleet-gitops}"
ARGOCD_NAME="${ARGOCD_NAME:-fleet-argocd}"
BLUE_NS="argocd-agent-blue-cluster"
RED_NS="argocd-agent-red-cluster"
BLUE_KUBECONFIG="${BLUE_KUBECONFIG:-/tmp/blue-cluster-kubeconfig}"
RED_KUBECONFIG="${RED_KUBECONFIG:-/tmp/red-cluster-kubeconfig}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --blue-kubeconfig) BLUE_KUBECONFIG="$2"; shift 2 ;;
    --red-kubeconfig) RED_KUBECONFIG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "=== ArgoCD Agent TLS Setup ==="
echo "Hub namespace: $PRINCIPAL_NS"
echo "Blue kubeconfig: $BLUE_KUBECONFIG"
echo "Red kubeconfig: $RED_KUBECONFIG"
echo ""

# --- Step 1: Ensure cert-manager is installed ---
echo "[1/7] Checking cert-manager operator..."
if oc get crd certificates.cert-manager.io &>/dev/null; then
  echo "  cert-manager CRDs found."
else
  echo "  Installing openshift-cert-manager-operator..."
  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  echo "  Waiting for CRDs..."
  for i in $(seq 1 60); do
    oc get crd certificates.cert-manager.io &>/dev/null && break || sleep 5
  done
  echo "  cert-manager ready."
fi

# Wait for cert-manager pods
echo "  Waiting for cert-manager pods..."
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s 2>/dev/null || true
echo ""

# --- Step 2: Create CA Issuer chain ---
echo "[2/7] Creating CA issuer chain..."
oc apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-root-ca
  namespace: fleet-gitops
spec:
  isCA: true
  commonName: "ArgoCD Agent Root CA"
  secretName: argocd-agent-root-ca
  duration: 87600h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: argocd-agent-ca-issuer
  namespace: fleet-gitops
spec:
  ca:
    secretName: argocd-agent-root-ca
EOF

echo "  Waiting for root CA certificate..."
oc wait --for=condition=Ready certificate/argocd-agent-root-ca -n "$PRINCIPAL_NS" --timeout=60s
echo ""

# --- Step 3: Discover the Principal's passthrough route ---
echo "[3/7] Discovering Principal agent-facing route..."
PRINCIPAL_ROUTE=$(oc get route -n "$PRINCIPAL_NS" "${ARGOCD_NAME}-agent-principal" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -z "$PRINCIPAL_ROUTE" ]; then
  echo "  ERROR: No passthrough route found for ${ARGOCD_NAME}-agent-principal"
  echo "  Ensure the ArgoCD Principal is deployed with argoCDAgent.principal.enabled=true"
  exit 1
fi
PRINCIPAL_PORT=$(oc get route -n "$PRINCIPAL_NS" "${ARGOCD_NAME}-agent-principal" -o jsonpath='{.spec.port.targetPort}' 2>/dev/null || echo "8443")
echo "  Principal route: $PRINCIPAL_ROUTE (port: $PRINCIPAL_PORT)"
echo "  TLS termination: $(oc get route -n "$PRINCIPAL_NS" "${ARGOCD_NAME}-agent-principal" -o jsonpath='{.spec.tls.termination}')"
echo ""

# --- Step 4: Issue Principal server certificate ---
echo "[4/7] Issuing Principal server certificate..."
PRINCIPAL_SVC="${ARGOCD_NAME}-agent-principal"
oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-principal-tls
  namespace: $PRINCIPAL_NS
spec:
  secretName: argocd-agent-principal-tls
  duration: 8760h
  renewBefore: 720h
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
  dnsNames:
    - "$PRINCIPAL_SVC"
    - "${PRINCIPAL_SVC}.${PRINCIPAL_NS}.svc"
    - "${PRINCIPAL_SVC}.${PRINCIPAL_NS}.svc.cluster.local"
    - "$PRINCIPAL_ROUTE"
  issuerRef:
    name: argocd-agent-ca-issuer
    kind: Issuer
    group: cert-manager.io
EOF
oc wait --for=condition=Ready certificate/argocd-agent-principal-tls -n "$PRINCIPAL_NS" --timeout=60s

# Issue resource proxy certificate (required by Principal for hub UI status streaming)
echo "  Issuing resource proxy TLS certificate..."
oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-resource-proxy-tls
  namespace: $PRINCIPAL_NS
spec:
  secretName: argocd-agent-resource-proxy-tls
  duration: 8760h
  renewBefore: 720h
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
  dnsNames:
    - "${ARGOCD_NAME}-agent-principal-redisproxy"
    - "${ARGOCD_NAME}-agent-principal-redisproxy.${PRINCIPAL_NS}.svc"
    - "${ARGOCD_NAME}-agent-principal-redisproxy.${PRINCIPAL_NS}.svc.cluster.local"
  issuerRef:
    name: argocd-agent-ca-issuer
    kind: Issuer
    group: cert-manager.io
EOF
oc wait --for=condition=Ready certificate/argocd-agent-resource-proxy-tls -n "$PRINCIPAL_NS" --timeout=60s
echo ""

# --- Step 5: Issue agent client certificates ---
echo "[5/7] Issuing agent client certificates..."
for CLUSTER in blue red; do
  oc apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-agent-${CLUSTER}-client-tls
  namespace: $PRINCIPAL_NS
spec:
  secretName: argocd-agent-${CLUSTER}-client-tls
  duration: 8760h
  renewBefore: 720h
  isCA: false
  commonName: "${CLUSTER}-cluster"
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - client auth
  issuerRef:
    name: argocd-agent-ca-issuer
    kind: Issuer
    group: cert-manager.io
EOF
  oc wait --for=condition=Ready "certificate/argocd-agent-${CLUSTER}-client-tls" -n "$PRINCIPAL_NS" --timeout=60s
done
echo ""

# --- Step 6: Configure Principal and update hub CA secret ---
echo "[6/7] Configuring Principal TLS and deploying certs to spokes..."

# Update the ArgoCD CR Principal TLS configuration
oc patch argocd "$ARGOCD_NAME" -n "$PRINCIPAL_NS" --type merge -p '{
  "spec": {
    "argoCDAgent": {
      "principal": {
        "tls": {
          "insecureGenerate": false,
          "rootCASecretName": "argocd-agent-root-ca",
          "secretName": "argocd-agent-principal-tls"
        }
      }
    }
  }
}'

# Ensure argocd-agent-ca on hub uses the cert-manager CA
CA_CRT=$(oc get secret argocd-agent-root-ca -n "$PRINCIPAL_NS" -o jsonpath='{.data.ca\.crt}' | b64decode)
oc delete secret argocd-agent-ca -n "$PRINCIPAL_NS" 2>/dev/null || true
oc create secret generic argocd-agent-ca --from-literal=ca.crt="$CA_CRT" -n "$PRINCIPAL_NS"

# Restart Principal to load new certs
oc delete pod -n "$PRINCIPAL_NS" -l "app.kubernetes.io/name=${ARGOCD_NAME}-agent-principal" --wait=false
sleep 5

# Deploy CA and client certs to blue-cluster
echo "  Deploying certs to blue-cluster..."
BLUE_CRT=$(oc get secret argocd-agent-blue-client-tls -n "$PRINCIPAL_NS" -o jsonpath='{.data.tls\.crt}' | b64decode)
BLUE_KEY=$(oc get secret argocd-agent-blue-client-tls -n "$PRINCIPAL_NS" -o jsonpath='{.data.tls\.key}' | b64decode)

KUBECONFIG="$BLUE_KUBECONFIG" oc create namespace "$BLUE_NS" --dry-run=client -o yaml | KUBECONFIG="$BLUE_KUBECONFIG" oc apply -f -
KUBECONFIG="$BLUE_KUBECONFIG" oc delete secret argocd-agent-ca -n "$BLUE_NS" 2>/dev/null || true
KUBECONFIG="$BLUE_KUBECONFIG" oc create secret generic argocd-agent-ca --from-literal=ca.crt="$CA_CRT" -n "$BLUE_NS"
KUBECONFIG="$BLUE_KUBECONFIG" oc delete secret argocd-agent-client-tls -n "$BLUE_NS" 2>/dev/null || true
echo "$BLUE_CRT" > /tmp/_blue.crt && echo "$BLUE_KEY" > /tmp/_blue.key
KUBECONFIG="$BLUE_KUBECONFIG" oc create secret tls argocd-agent-client-tls --cert=/tmp/_blue.crt --key=/tmp/_blue.key -n "$BLUE_NS"
rm -f /tmp/_blue.crt /tmp/_blue.key

# Deploy CA and client certs to red-cluster
echo "  Deploying certs to red-cluster..."
RED_CRT=$(oc get secret argocd-agent-red-client-tls -n "$PRINCIPAL_NS" -o jsonpath='{.data.tls\.crt}' | b64decode)
RED_KEY=$(oc get secret argocd-agent-red-client-tls -n "$PRINCIPAL_NS" -o jsonpath='{.data.tls\.key}' | b64decode)

KUBECONFIG="$RED_KUBECONFIG" oc create namespace "$RED_NS" --dry-run=client -o yaml | KUBECONFIG="$RED_KUBECONFIG" oc apply -f -
KUBECONFIG="$RED_KUBECONFIG" oc delete secret argocd-agent-ca -n "$RED_NS" 2>/dev/null || true
KUBECONFIG="$RED_KUBECONFIG" oc create secret generic argocd-agent-ca --from-literal=ca.crt="$CA_CRT" -n "$RED_NS"
KUBECONFIG="$RED_KUBECONFIG" oc delete secret argocd-agent-client-tls -n "$RED_NS" 2>/dev/null || true
echo "$RED_CRT" > /tmp/_red.crt && echo "$RED_KEY" > /tmp/_red.key
KUBECONFIG="$RED_KUBECONFIG" oc create secret tls argocd-agent-client-tls --cert=/tmp/_red.crt --key=/tmp/_red.key -n "$RED_NS"
rm -f /tmp/_red.crt /tmp/_red.key
echo ""

# --- Step 7: Deploy/update ArgoCD Agent CRs on spokes ---
echo "[7/7] Deploying ArgoCD Agent CRs on spoke clusters..."

# Blue cluster agent
KUBECONFIG="$BLUE_KUBECONFIG" oc apply -f - <<EOF
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: agent-argocd
  namespace: $BLUE_NS
spec:
  server:
    enabled: false
  argoCDAgent:
    agent:
      enabled: true
      client:
        principalServerAddress: "$PRINCIPAL_ROUTE"
        principalServerPort: "443"
      tls:
        rootCASecretName: argocd-agent-ca
        secretName: argocd-agent-client-tls
EOF

# Red cluster agent
KUBECONFIG="$RED_KUBECONFIG" oc apply -f - <<EOF
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: agent-argocd
  namespace: $RED_NS
spec:
  server:
    enabled: false
  argoCDAgent:
    agent:
      enabled: true
      client:
        principalServerAddress: "$PRINCIPAL_ROUTE"
        principalServerPort: "443"
      tls:
        rootCASecretName: argocd-agent-ca
        secretName: argocd-agent-client-tls
EOF

# Grant cluster-admin to agent service accounts (needed for reconciliation)
for CLUSTER_KC in "$BLUE_KUBECONFIG:$BLUE_NS" "$RED_KUBECONFIG:$RED_NS"; do
  KC="${CLUSTER_KC%%:*}"
  NS="${CLUSTER_KC##*:}"
  KUBECONFIG="$KC" oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agent-argocd-agent-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: agent-argocd-agent-agent
  namespace: $NS
EOF
done

# Restart agent pods to pick up new certs
KUBECONFIG="$BLUE_KUBECONFIG" oc delete pod -n "$BLUE_NS" -l app.kubernetes.io/component=agent --wait=false 2>/dev/null || true
KUBECONFIG="$RED_KUBECONFIG" oc delete pod -n "$RED_NS" -l app.kubernetes.io/component=agent --wait=false 2>/dev/null || true

echo ""
echo "=== Waiting for agents to connect... ==="
sleep 15

# Check status
echo ""
echo "--- Blue Agent Status ---"
KUBECONFIG="$BLUE_KUBECONFIG" oc get pods -n "$BLUE_NS" -l app.kubernetes.io/component=agent
echo ""
echo "--- Red Agent Status ---"
KUBECONFIG="$RED_KUBECONFIG" oc get pods -n "$RED_NS" -l app.kubernetes.io/component=agent
echo ""

# Check logs for connectivity
echo "--- Blue Agent Connection Log ---"
KUBECONFIG="$BLUE_KUBECONFIG" oc logs -n "$BLUE_NS" -l app.kubernetes.io/component=agent --tail=5 2>/dev/null || echo "  (pod not ready yet)"
echo ""
echo "--- Red Agent Connection Log ---"
KUBECONFIG="$RED_KUBECONFIG" oc logs -n "$RED_NS" -l app.kubernetes.io/component=agent --tail=5 2>/dev/null || echo "  (pod not ready yet)"
echo ""

echo "=== Configuring namespace management on spokes ==="

for SPOKE_KC in "$BLUE_KUBECONFIG" "$RED_KUBECONFIG"; do
  SPOKE_NS=$(KUBECONFIG="$SPOKE_KC" oc get argocd -A -o jsonpath='{.items[0].metadata.namespace}')
  echo "Configuring $SPOKE_NS..."

  # Enable destination-based mapping with createNamespace
  KUBECONFIG="$SPOKE_KC" oc patch argocd agent-argocd -n "$SPOKE_NS" --type merge \
    -p '{"spec":{"argoCDAgent":{"agent":{"allowedNamespaces":["fleet-gitops"]}}}}' 2>/dev/null || true

  # Set ARGOCD_APPLICATION_NAMESPACES on controller
  KUBECONFIG="$SPOKE_KC" oc patch argocd agent-argocd -n "$SPOKE_NS" --type merge \
    -p '{"spec":{"controller":{"env":[{"name":"ARGOCD_APPLICATION_NAMESPACES","value":"fleet-gitops"}]}}}' 2>/dev/null || true

  # Grant cluster-admin to app controller SA for cross-namespace watches
  KUBECONFIG="$SPOKE_KC" oc adm policy add-cluster-role-to-user cluster-admin \
    "system:serviceaccount:${SPOKE_NS}:agent-argocd-argocd-application-controller" 2>/dev/null || true
done

echo "=== Configuring Redis proxy on hub ==="
oc patch configmap argocd-cmd-params-cm -n "$PRINCIPAL_NS" --type merge \
  -p '{"data":{"redis.server":"fleet-argocd-agent-principal-redisproxy:6379"}}' 2>/dev/null || true

echo "=== TLS Setup Complete ==="
echo ""
echo "Principal route (passthrough): $PRINCIPAL_ROUTE"
echo "Certificates managed by: cert-manager (auto-rotation enabled)"
echo ""
echo "Post-setup steps:"
echo "  1. Create AppProjects on spoke clusters (in the agent namespace)"
echo "  2. Label target namespaces: oc label ns <name> argocd.argoproj.io/managed-by=agent-argocd"
echo "  3. Add target namespaces to cluster secret's 'namespaces' field"
echo ""
echo "If agents still show TLS errors, verify:"
echo "  1. The Principal pod has restarted and loaded the new cert"
echo "  2. The CA in argocd-agent-ca on spokes matches the root CA on hub"
echo "  3. The agent's principalServerAddress points to the passthrough route"
