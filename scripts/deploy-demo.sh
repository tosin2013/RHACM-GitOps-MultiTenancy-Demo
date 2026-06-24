#!/usr/bin/env bash
set -euo pipefail

# deploy-demo.sh — One-command deployment for RHACM GitOps Multi-Tenancy Demo
#
# Auto-detects the RHPDS environment and orchestrates the full Principal/Agent
# fleet GitOps deployment. Calls existing modular scripts in the correct order.
#
# Usage:
#   ./scripts/deploy-demo.sh [OPTIONS]
#
# Options:
#   --skip-users       Skip user/group setup
#   --skip-clusters    Skip spoke cluster provisioning (assumes they exist)
#   --skip-tls         Skip TLS/agent setup (assumes certs already configured)
#   --dry-run          Show what would be done without executing
#   --password PASS    Password for demo users (default: $USER_PASSWORD or "openshift")
#   --pull-secret PATH Path to pull-secret.json (default: ~/pull-secret.json)
#   --base-domain DOM  Override auto-detected base domain for spoke provisioning
#   --help             Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

SKIP_USERS=false
SKIP_CLUSTERS=false
SKIP_TLS=false
DRY_RUN=false
USER_PASSWORD="${USER_PASSWORD:-openshift}"
PULL_SECRET="${PULL_SECRET:-$HOME/pull-secret.json}"
BASE_DOMAIN_OVERRIDE="${BASE_DOMAIN:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-users)    SKIP_USERS=true; shift ;;
    --skip-clusters) SKIP_CLUSTERS=true; shift ;;
    --skip-tls)      SKIP_TLS=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --password)      USER_PASSWORD="$2"; shift 2 ;;
    --pull-secret)   PULL_SECRET="$2"; shift 2 ;;
    --base-domain)   BASE_DOMAIN_OVERRIDE="$2"; shift 2 ;;
    --help)
      head -20 "$0" | grep "^#" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo "  [DRY-RUN] $*"
  else
    "$@"
  fi
}

wait_for_condition() {
  local resource="$1" condition="$2" ns="${3:-}" timeout="${4:-300}"
  local ns_flag=""
  [[ -n "$ns" ]] && ns_flag="-n $ns"
  echo "  Waiting for $resource ($condition)..."
  if ! $DRY_RUN; then
    oc wait "$resource" $ns_flag --for="$condition" --timeout="${timeout}s" 2>/dev/null || true
  fi
}

banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
banner "Phase 1: Environment Detection"
# ============================================================================

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into an OpenShift cluster."
  echo "  Run 'oc login --token=<token> --server=https://<hub-api>:6443' first."
  exit 1
fi

HUB_API=$(oc whoami --show-server)
HUB_USER=$(oc whoami)
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "unknown")

# Extract base domain for spoke cluster provisioning.
# The hub's ingress domain is like: apps.cluster-xb7dm.dynamic2.redhatworkshops.io
# The hub's own domain is:          cluster-xb7dm.dynamic2.redhatworkshops.io
# For spoke provisioning we need the PARENT: dynamic2.redhatworkshops.io
# (Hive creates spokes as blue-cluster.<BASE_DOMAIN>)
HUB_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//')
APPS_DOMAIN="apps.${HUB_DOMAIN}"

if [[ -n "$BASE_DOMAIN_OVERRIDE" ]]; then
  BASE_DOMAIN="$BASE_DOMAIN_OVERRIDE"
else
  BASE_DOMAIN=$(echo "$HUB_DOMAIN" | sed 's/^[^.]*\.//')
fi

echo "  Hub API:      $HUB_API"
echo "  Logged in as: $HUB_USER"
echo "  Console:      $CONSOLE_URL"
echo "  Hub Domain:   $HUB_DOMAIN"
echo "  Base Domain:  $BASE_DOMAIN (for spoke provisioning)"
echo "  Apps Domain:  $APPS_DOMAIN"
echo ""
echo "  Spoke clusters will be provisioned as:"
echo "    blue-cluster.$BASE_DOMAIN"
echo "    red-cluster.$BASE_DOMAIN"

if ! $SKIP_CLUSTERS && ! $DRY_RUN; then
  echo ""
  read -rp "  Is this base domain correct for spoke provisioning? [Y/n] " answer
  if [[ "$answer" =~ ^[Nn]$ ]]; then
    read -rp "  Enter the correct base domain: " BASE_DOMAIN
    echo "  Updated base domain: $BASE_DOMAIN"
  fi
fi

# Detect Keycloak
KEYCLOAK_DETECTED=false
if oc get namespace keycloak &>/dev/null 2>&1; then
  if oc get pods -n keycloak -l app=keycloak --no-headers 2>/dev/null | grep -q Running; then
    KEYCLOAK_DETECTED=true
  fi
fi
echo "  Keycloak:     $KEYCLOAK_DETECTED"

# Verify ACM is installed
if ! oc get multiclusterhub -A --no-headers 2>/dev/null | grep -q Running; then
  echo ""
  echo "WARNING: RHACM MultiClusterHub not found or not Running."
  echo "  This demo requires RHACM 2.15+ on the hub cluster."
  echo "  Verify with: oc get multiclusterhub -A"
  read -rp "  Continue anyway? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 1
fi

# Check pull-secret
if [[ ! -f "$PULL_SECRET" ]]; then
  echo ""
  echo "WARNING: Pull secret not found at $PULL_SECRET"
  echo "  Download from: https://console.redhat.com/openshift/install/pull-secret"
  if ! $SKIP_CLUSTERS; then
    echo "  Cluster provisioning requires a pull secret."
    read -rp "  Continue without pull secret? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 1
  fi
else
  echo "  Pull Secret:  $PULL_SECRET"
fi

# Check AWS credentials
AWS_CREDS_AVAILABLE=false
if oc get secret aws-credentials -n aws-credentials &>/dev/null 2>&1; then
  AWS_CREDS_AVAILABLE=true
  echo "  AWS Creds:    Found (aws-credentials/aws-credentials)"
elif [[ -f "$HOME/.aws/credentials" ]]; then
  AWS_CREDS_AVAILABLE=true
  echo "  AWS Creds:    Found (~/.aws/credentials)"
else
  echo "  AWS Creds:    Not found"
  if ! $SKIP_CLUSTERS; then
    echo "  WARNING: Cluster provisioning requires AWS credentials."
  fi
fi

echo ""
echo "  Configuration:"
echo "    Skip Users:    $SKIP_USERS"
echo "    Skip Clusters: $SKIP_CLUSTERS"
echo "    Skip TLS:      $SKIP_TLS"
echo "    Dry Run:       $DRY_RUN"

if ! $DRY_RUN; then
  echo ""
  read -rp "  Proceed with deployment? [Y/n] " answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] || exit 0
fi

# ============================================================================
banner "Phase 2: Foundation (Users + GitOps Operator)"
# ============================================================================

if ! $SKIP_USERS; then
  echo "[2.1] Setting up users and groups..."
  run bash "$SCRIPT_DIR/setup-users.sh" --password "$USER_PASSWORD"
else
  echo "[2.1] Skipping user setup (--skip-users)"
fi

echo "[2.2] Installing GitOps operator via ACM policy..."
run oc apply -k "$REPO_DIR/AcmPolicies/InstallGitOpsOperator"

echo "[2.3] Waiting for OpenShift GitOps operator..."
if ! $DRY_RUN; then
  for i in $(seq 1 60); do
    if oc get csv -n openshift-gitops --no-headers 2>/dev/null | grep -q Succeeded; then
      echo "  GitOps operator is ready."
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo "  WARNING: GitOps operator not ready after 5 minutes. Continuing..."
    fi
    sleep 5
  done
fi

# ============================================================================
banner "Phase 3: Deploy Principal (fleet-argocd)"
# ============================================================================

echo "[3.1] Applying Fleet ArgoCD policy..."
run oc apply -k "$REPO_DIR/AcmPolicies/FleetArgoCD"

echo "[3.2] Waiting for fleet-argocd Principal pods..."
if ! $DRY_RUN; then
  sleep 10
  for i in $(seq 1 60); do
    READY=$(oc get pods -n fleet-gitops -l app.kubernetes.io/part-of=argocd --no-headers 2>/dev/null | grep -c Running || echo 0)
    if [[ "$READY" -ge 3 ]]; then
      echo "  fleet-argocd pods ready ($READY running)."
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo "  WARNING: Principal pods not ready after 5 minutes."
      oc get pods -n fleet-gitops 2>/dev/null || true
    fi
    sleep 5
  done
fi

# ============================================================================
banner "Phase 4: Spoke Cluster Provisioning"
# ============================================================================

if $SKIP_CLUSTERS; then
  echo "  Skipping cluster provisioning (--skip-clusters)"
  echo "  Checking for existing managed clusters..."
  if ! $DRY_RUN; then
    oc get managedcluster --no-headers 2>/dev/null || echo "  No managed clusters found."
  fi
else
  echo "[4.1] Running pre-deployment checks..."
  if ! $DRY_RUN; then
    bash "$REPO_DIR/cluster-provisioning/pre-deploy-check.sh" || {
      echo ""
      echo "  Pre-deployment check reported issues. Review and fix before continuing."
      read -rp "  Continue with cluster provisioning? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || exit 1
    }
  fi

  echo "[4.2] Generating cluster provisioning manifests..."
  export BASE_DOMAIN
  for CLUSTER in blue-cluster red-cluster; do
    TEMPLATE="$REPO_DIR/cluster-provisioning/${CLUSTER}.yaml.tpl"
    OUTPUT="$REPO_DIR/cluster-provisioning/${CLUSTER}.yaml"
    if [[ -f "$TEMPLATE" ]]; then
      echo "  Generating $CLUSTER manifest from template (baseDomain=$BASE_DOMAIN)..."
      run envsubst < "$TEMPLATE" > "$OUTPUT"
    else
      echo "  Using existing $CLUSTER manifest (no template found)."
    fi
  done

  echo "[4.3] Preparing cluster namespaces and secrets..."
  if ! $DRY_RUN; then
    for NS in blue-cluster red-cluster; do
      oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
      if [[ -f "$PULL_SECRET" ]]; then
        oc create secret generic pull-secret -n "$NS" \
          --from-file=.dockerconfigjson="$PULL_SECRET" \
          --type=kubernetes.io/dockerconfigjson \
          --dry-run=client -o yaml | oc apply -f -
      fi
      # Copy AWS credentials to cluster namespace if available on cluster
      if oc get secret aws-credentials -n aws-credentials &>/dev/null; then
        AWS_KEY=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
        AWS_SECRET_KEY=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
        oc create secret generic aws-credentials -n "$NS" \
          --from-literal=aws_access_key_id="$AWS_KEY" \
          --from-literal=aws_secret_access_key="$AWS_SECRET_KEY" \
          --dry-run=client -o yaml | oc apply -f -
      fi
      # Copy SSH key if it exists
      if [[ -f "$HOME/.ssh/id_rsa" ]]; then
        oc create secret generic "${NS}-ssh-private-key" -n "$NS" \
          --from-file=ssh-privatekey="$HOME/.ssh/id_rsa" \
          --dry-run=client -o yaml | oc apply -f -
      fi
    done
  fi

  echo "[4.4] Creating ManagedClusterSets..."
  run oc apply -f - <<'EOF'
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

  echo "[4.5] Applying ClusterDeployments..."
  run oc apply -f "$REPO_DIR/cluster-provisioning/blue-cluster.yaml"
  run oc apply -f "$REPO_DIR/cluster-provisioning/red-cluster.yaml"

  echo "[4.6] Waiting for spoke clusters to be ready..."
  echo "  This typically takes 30-45 minutes for SNO clusters on AWS."
  if ! $DRY_RUN; then
    TIMEOUT=3600
    START=$(date +%s)
    while true; do
      BLUE_READY=$(oc get managedcluster blue-cluster -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "")
      RED_READY=$(oc get managedcluster red-cluster -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "")

      if [[ "$BLUE_READY" == "True" && "$RED_READY" == "True" ]]; then
        echo "  Both spoke clusters are ready!"
        break
      fi

      ELAPSED=$(( $(date +%s) - START ))
      if [[ $ELAPSED -ge $TIMEOUT ]]; then
        echo "  TIMEOUT: Clusters not ready after $((TIMEOUT/60)) minutes."
        echo "  blue-cluster: $BLUE_READY"
        echo "  red-cluster: $RED_READY"
        echo "  Check: oc get clusterdeployment -A"
        exit 1
      fi

      printf "  [%dm] blue=%s red=%s — waiting...\r" $((ELAPSED/60)) "${BLUE_READY:-Pending}" "${RED_READY:-Pending}"
      sleep 30
    done
  fi
fi

# ============================================================================
banner "Phase 5: Agent TLS + Deployment"
# ============================================================================

if $SKIP_TLS; then
  echo "  Skipping TLS/agent setup (--skip-tls)"
else
  echo "[5.1] Extracting spoke kubeconfigs from Hive..."
  BLUE_KUBECONFIG="/tmp/blue-cluster-kubeconfig"
  RED_KUBECONFIG="/tmp/red-cluster-kubeconfig"

  if ! $DRY_RUN; then
    # Try to extract kubeconfig from Hive admin secret
    BLUE_SECRET=$(oc get clusterdeployment blue-cluster -n blue-cluster -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null || echo "")
    RED_SECRET=$(oc get clusterdeployment red-cluster -n red-cluster -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null || echo "")

    if [[ -n "$BLUE_SECRET" ]]; then
      oc get secret "$BLUE_SECRET" -n blue-cluster -o jsonpath='{.data.kubeconfig}' | base64 -d > "$BLUE_KUBECONFIG"
      echo "  Blue kubeconfig extracted to $BLUE_KUBECONFIG"
    elif [[ -f "$BLUE_KUBECONFIG" ]]; then
      echo "  Using existing $BLUE_KUBECONFIG"
    else
      echo "  ERROR: Cannot find blue-cluster kubeconfig."
      echo "  Provide via: export BLUE_KUBECONFIG=/path/to/kubeconfig"
      exit 1
    fi

    if [[ -n "$RED_SECRET" ]]; then
      oc get secret "$RED_SECRET" -n red-cluster -o jsonpath='{.data.kubeconfig}' | base64 -d > "$RED_KUBECONFIG"
      echo "  Red kubeconfig extracted to $RED_KUBECONFIG"
    elif [[ -f "$RED_KUBECONFIG" ]]; then
      echo "  Using existing $RED_KUBECONFIG"
    else
      echo "  ERROR: Cannot find red-cluster kubeconfig."
      echo "  Provide via: export RED_KUBECONFIG=/path/to/kubeconfig"
      exit 1
    fi
  fi

  echo "[5.2] Running Agent TLS setup (cert-manager)..."
  run bash "$SCRIPT_DIR/setup-agent-tls.sh" \
    --blue-kubeconfig "$BLUE_KUBECONFIG" \
    --red-kubeconfig "$RED_KUBECONFIG"
fi

# ============================================================================
banner "Phase 6: Applications + Fleet Registration"
# ============================================================================

echo "[6.1] Registering clusters to fleet..."
run oc apply -k "$REPO_DIR/AcmPolicies/RegisterAllClustersToFleet"

echo "[6.2] Deploying ApplicationSets..."
run oc apply -k "$REPO_DIR/ApplicationSets/fleet"

echo "[6.3] Verifying deployment..."
if ! $DRY_RUN; then
  sleep 15
  echo ""
  echo "  Managed Clusters:"
  oc get managedcluster --no-headers 2>/dev/null || echo "    (none)"
  echo ""
  echo "  ArgoCD Applications (fleet-gitops):"
  oc get applications.argoproj.io -n fleet-gitops --no-headers 2>/dev/null || echo "    (none)"
  echo ""
  echo "  ApplicationSets:"
  oc get applicationsets -n fleet-gitops --no-headers 2>/dev/null || echo "    (none)"
fi

# ============================================================================
banner "Deployment Complete"
# ============================================================================

ARGOCD_ROUTE=$(oc get route fleet-argocd-server -n fleet-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
ARGOCD_PASSWORD=$(oc get secret fleet-argocd-cluster -n fleet-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

echo ""
echo "  ArgoCD UI:  https://${ARGOCD_ROUTE:-<not-found>}"
echo "  Username:   admin"
if [[ -n "$ARGOCD_PASSWORD" ]]; then
  echo "  Password:   $ARGOCD_PASSWORD"
else
  echo "  Password:   (retrieve with: oc get secret fleet-argocd-cluster -n fleet-gitops -o jsonpath='{.data.admin\\.password}' | base64 -d)"
fi
echo ""
echo "  Console:    $CONSOLE_URL"
echo "  Demo Users: bluesre1, redsre1, acmsre1 (password: $USER_PASSWORD)"
echo ""
echo "  Documentation:"
echo "    Architecture:    $REPO_DIR/docs/architecture.md"
echo "    Troubleshooting: $REPO_DIR/docs/troubleshooting.md"
echo "    User Management: $REPO_DIR/docs/user-management.md"
echo ""
echo "Done."
