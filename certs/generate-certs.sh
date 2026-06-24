#!/bin/bash
set -euo pipefail

# DEPRECATED: This script generates static OpenSSL certificates that require
# manual rotation and manual secret deployment to spoke clusters.
#
# Prefer: scripts/setup-agent-tls.sh
#   - Uses cert-manager operator for automated certificate lifecycle
#   - Auto-discovers the Principal route address
#   - Deploys certs AND Agent CRs to spoke clusters in one step
#
# This script is retained for environments where cert-manager is unavailable.

echo "WARNING: certs/generate-certs.sh is deprecated."
echo "  Recommended: bash scripts/setup-agent-tls.sh"
echo "  (uses cert-manager for automated certificate lifecycle)"
echo ""
read -rp "Continue with manual OpenSSL certificate generation? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

CERT_DIR="$(cd "$(dirname "$0")" && pwd)/generated"
mkdir -p "$CERT_DIR"

echo "=== Generating mTLS certificates for ArgoCD Principal/Agent ==="
echo "Output directory: $CERT_DIR"
echo ""

# Generate Root CA
echo "[1/5] Generating Root CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 365 \
  -out "$CERT_DIR/ca.crt" -subj "/CN=fleet-argocd-ca"
echo "  -> ca.key, ca.crt"

# Generate Hub (Principal) certificate
echo "[2/5] Generating Hub Principal certificate..."
openssl genrsa -out "$CERT_DIR/hub.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/hub.key" -out "$CERT_DIR/hub.csr" \
  -subj "/CN=fleet-argocd-principal"
openssl x509 -req -in "$CERT_DIR/hub.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial -out "$CERT_DIR/hub.crt" -days 365 -sha256 2>/dev/null
echo "  -> hub.key, hub.crt"

# Generate Blue Agent leaf certificate
echo "[3/5] Generating Blue Agent leaf certificate (CN=blue-cluster)..."
openssl genrsa -out "$CERT_DIR/blue-agent.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/blue-agent.key" -out "$CERT_DIR/blue-agent.csr" \
  -subj "/CN=blue-cluster"
openssl x509 -req -in "$CERT_DIR/blue-agent.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial -out "$CERT_DIR/blue-agent.crt" -days 365 -sha256 2>/dev/null
echo "  -> blue-agent.key, blue-agent.crt"

# Generate Red Agent leaf certificate
echo "[4/5] Generating Red Agent leaf certificate (CN=red-cluster)..."
openssl genrsa -out "$CERT_DIR/red-agent.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/red-agent.key" -out "$CERT_DIR/red-agent.csr" \
  -subj "/CN=red-cluster"
openssl x509 -req -in "$CERT_DIR/red-agent.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial -out "$CERT_DIR/red-agent.crt" -days 365 -sha256 2>/dev/null
echo "  -> red-agent.key, red-agent.crt"

# Summary
echo ""
echo "[5/5] Certificate generation complete."
echo ""
echo "Files generated:"
ls -la "$CERT_DIR"/*.{key,crt} 2>/dev/null
echo ""
echo "Next steps:"
echo "  1. Create TLS secret on hub:    oc create secret tls fleet-argocd-agent-tls -n fleet-gitops --cert=$CERT_DIR/ca.crt --key=$CERT_DIR/ca.key"
echo "  2. Create secret on blue spoke: oc create secret generic argocd-agent-tls -n argocd-agent-blue-cluster --from-file=ca.crt=$CERT_DIR/ca.crt --from-file=tls.crt=$CERT_DIR/blue-agent.crt --from-file=tls.key=$CERT_DIR/blue-agent.key"
echo "  3. Create secret on red spoke:  oc create secret generic argocd-agent-tls -n argocd-agent-red-cluster --from-file=ca.crt=$CERT_DIR/ca.crt --from-file=tls.crt=$CERT_DIR/red-agent.crt --from-file=tls.key=$CERT_DIR/red-agent.key"
