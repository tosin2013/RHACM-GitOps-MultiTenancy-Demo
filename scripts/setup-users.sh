#!/usr/bin/env bash
set -euo pipefail

# Setup demo users for RHACM GitOps Multi-Tenancy Demo
# Supports two modes:
#   1. Keycloak (RHBK) — if detected, creates users/groups in Keycloak and configures OIDC
#   2. htpasswd fallback — if no Keycloak, uses htpasswd identity provider
#
# Usage:
#   ./setup-users.sh [--password PASSWORD] [--force-htpasswd]

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: This script requires bash 4+ (for associative arrays)."
  echo "  macOS ships bash 3.x by default. Install newer bash:"
  echo "    brew install bash"
  echo "  Then run: /opt/homebrew/bin/bash $0 $*"
  exit 1
fi

# Cross-platform base64 decode (macOS uses -D, Linux uses -d)
b64decode() {
  case "$(uname -s)" in
    Darwin) base64 -D ;;
    *)      base64 -d ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER_PASSWORD="${USER_PASSWORD:-openshift}"
FORCE_HTPASSWD=false
KEYCLOAK_NS="keycloak"

while [[ $# -gt 0 ]]; do
  case $1 in
    --password) USER_PASSWORD="$2"; shift 2 ;;
    --force-htpasswd) FORCE_HTPASSWD=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

USERS=(bluesre1 bluesre2 redsre1 redsre2 blueviewer1 blueviewer2 redviewer1 redviewer2 acmsre1 acmsre2 acmviewer1 acmviewer2)

declare -A USER_GROUPS
USER_GROUPS[bluesre1]=blue-sre-group
USER_GROUPS[bluesre2]=blue-sre-group
USER_GROUPS[redsre1]=red-sre-group
USER_GROUPS[redsre2]=red-sre-group
USER_GROUPS[blueviewer1]=blue-viewer-group
USER_GROUPS[blueviewer2]=blue-viewer-group
USER_GROUPS[redviewer1]=red-viewer-group
USER_GROUPS[redviewer2]=red-viewer-group
USER_GROUPS[acmsre1]=acm-sre-group
USER_GROUPS[acmsre2]=acm-sre-group
USER_GROUPS[acmviewer1]=acm-viewer-group
USER_GROUPS[acmviewer2]=acm-viewer-group

declare -A USER_FIRST
USER_FIRST[bluesre1]=Blue; USER_FIRST[bluesre2]=Blue
USER_FIRST[redsre1]=Red; USER_FIRST[redsre2]=Red
USER_FIRST[blueviewer1]=Blue; USER_FIRST[blueviewer2]=Blue
USER_FIRST[redviewer1]=Red; USER_FIRST[redviewer2]=Red
USER_FIRST[acmsre1]=ACM; USER_FIRST[acmsre2]=ACM
USER_FIRST[acmviewer1]=ACM; USER_FIRST[acmviewer2]=ACM

declare -A USER_LAST
USER_LAST[bluesre1]=SRE1; USER_LAST[bluesre2]=SRE2
USER_LAST[redsre1]=SRE1; USER_LAST[redsre2]=SRE2
USER_LAST[blueviewer1]=Viewer1; USER_LAST[blueviewer2]=Viewer2
USER_LAST[redviewer1]=Viewer1; USER_LAST[redviewer2]=Viewer2
USER_LAST[acmsre1]=SRE1; USER_LAST[acmsre2]=SRE2
USER_LAST[acmviewer1]=Viewer1; USER_LAST[acmviewer2]=Viewer2

GROUPS=(blue-sre-group red-sre-group blue-viewer-group red-viewer-group acm-sre-group acm-viewer-group)

detect_keycloak() {
  if [[ "$FORCE_HTPASSWD" == "true" ]]; then
    return 1
  fi
  oc get pods -n "$KEYCLOAK_NS" -l app=keycloak --no-headers 2>/dev/null | grep -q Running
}

setup_keycloak() {
  echo "=== Keycloak detected — configuring OIDC identity provider ==="

  KC_ROUTE=$(oc get route keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.spec.host}')
  KC_URL="https://$KC_ROUTE"
  echo "Keycloak URL: $KC_URL"

  # Get admin credentials from the initial-admin secret
  KC_ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$KEYCLOAK_NS" -o jsonpath='{.data.username}' | b64decode)
  KC_ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KEYCLOAK_NS" -o jsonpath='{.data.password}' | b64decode)

  # Get admin token
  TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" \
    -d "password=$KC_ADMIN_PASS" \
    -d "grant_type=password" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['access_token'])")

  if [[ -z "$TOKEN" || "$TOKEN" == "None" ]]; then
    echo "ERROR: Failed to get Keycloak admin token"
    exit 1
  fi

  # Check if realm 'sso' exists
  REALM_EXISTS=$(curl -sk -o /dev/null -w "%{http_code}" "$KC_URL/admin/realms/sso" \
    -H "Authorization: Bearer $TOKEN")

  if [[ "$REALM_EXISTS" != "200" ]]; then
    echo "Creating realm 'sso'..."
    curl -sk -X POST "$KC_URL/admin/realms" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"realm":"sso","enabled":true}'
  fi

  # Create groups
  echo "Creating groups..."
  for GROUP in "${GROUPS[@]}"; do
    curl -sk -o /dev/null -X POST "$KC_URL/admin/realms/sso/groups" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$GROUP\"}" 2>/dev/null || true
  done

  # Get group IDs
  declare -A GROUP_IDS
  for GROUP in "${GROUPS[@]}"; do
    GID=$(curl -sk "$KC_URL/admin/realms/sso/groups?search=$GROUP" \
      -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; groups=json.loads(sys.stdin.read()); print(groups[0]['id'] if groups else '')" 2>/dev/null)
    GROUP_IDS[$GROUP]=$GID
  done

  # Create users
  echo "Creating users..."
  for USER in "${USERS[@]}"; do
    FIRST="${USER_FIRST[$USER]}"
    LAST="${USER_LAST[$USER]}"
    GROUP="${USER_GROUPS[$USER]}"

    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/sso/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$USER\",\"enabled\":true,\"firstName\":\"$FIRST\",\"lastName\":\"$LAST\",\"email\":\"${USER}@demo.redhat.com\",\"credentials\":[{\"type\":\"password\",\"value\":\"$USER_PASSWORD\",\"temporary\":false}]}")

    if [[ "$HTTP_CODE" == "201" ]]; then
      echo "  Created $USER"
    elif [[ "$HTTP_CODE" == "409" ]]; then
      echo "  $USER already exists"
    else
      echo "  WARNING: $USER returned HTTP $HTTP_CODE"
    fi

    # Assign to group
    USER_ID=$(curl -sk "$KC_URL/admin/realms/sso/users?username=$USER&exact=true" \
      -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; users=json.loads(sys.stdin.read()); print(users[0]['id'] if users else '')" 2>/dev/null)
    GID="${GROUP_IDS[$GROUP]:-}"
    if [[ -n "$USER_ID" && -n "$GID" ]]; then
      curl -sk -o /dev/null -X PUT "$KC_URL/admin/realms/sso/users/$USER_ID/groups/$GID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json"
    fi
  done

  # Also add admin to acm-sre-group
  ADMIN_ID=$(curl -sk "$KC_URL/admin/realms/sso/users?username=admin&exact=true" \
    -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; users=json.loads(sys.stdin.read()); print(users[0]['id'] if users else '')" 2>/dev/null)
  if [[ -n "$ADMIN_ID" ]]; then
    curl -sk -o /dev/null -X PUT "$KC_URL/admin/realms/sso/users/$ADMIN_ID/groups/${GROUP_IDS[acm-sre-group]:-}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json"
    echo "  Added admin to acm-sre-group"
  fi

  # Ensure OIDC client has groups mapper
  CLIENT_UUID=$(curl -sk "$KC_URL/admin/realms/sso/clients?clientId=idp-4-ocp" \
    -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; clients=json.loads(sys.stdin.read()); print(clients[0]['id'] if clients else '')" 2>/dev/null)

  if [[ -n "$CLIENT_UUID" ]]; then
    # Check if groups mapper already exists
    MAPPER_EXISTS=$(curl -sk "$KC_URL/admin/realms/sso/clients/$CLIENT_UUID/protocol-mappers/models" \
      -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; mappers=json.loads(sys.stdin.read()); print('yes' if any(m['name']=='groups' for m in mappers) else 'no')" 2>/dev/null)

    if [[ "$MAPPER_EXISTS" != "yes" ]]; then
      echo "Adding groups claim mapper to OIDC client..."
      curl -sk -o /dev/null -X POST "$KC_URL/admin/realms/sso/clients/$CLIENT_UUID/protocol-mappers/models" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}'
    fi
  fi

  # Configure OAuth on OpenShift
  echo "Configuring OpenShift OAuth..."

  # Create client secret if not exists
  oc get secret rhbk-oidc-client-secret -n openshift-config &>/dev/null || \
    oc create secret generic rhbk-oidc-client-secret \
      --from-literal=clientSecret=JPhsRcVazN \
      -n openshift-config

  # Check if rhbk provider already exists in OAuth
  PROVIDERS=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}')
  if [[ "$PROVIDERS" != *"rhbk"* ]]; then
    echo "Adding RHBK OIDC provider to OAuth..."
    oc patch oauth cluster --type=json -p "[{
      \"op\": \"add\",
      \"path\": \"/spec/identityProviders/-\",
      \"value\": {
        \"mappingMethod\": \"claim\",
        \"name\": \"rhbk\",
        \"type\": \"OpenID\",
        \"openID\": {
          \"clientID\": \"idp-4-ocp\",
          \"clientSecret\": {\"name\": \"rhbk-oidc-client-secret\"},
          \"issuer\": \"$KC_URL/realms/sso\",
          \"claims\": {
            \"preferredUsername\": [\"preferred_username\"],
            \"name\": [\"name\"],
            \"email\": [\"email\"],
            \"groups\": [\"groups\"]
          }
        }
      }
    }]"
  else
    echo "RHBK OIDC provider already configured in OAuth"
  fi

  echo ""
  echo "=== Keycloak setup complete ==="
  echo "Login URL: $(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
  echo "Select 'rhbk' identity provider at login screen"
  echo "All users password: $USER_PASSWORD"
}

setup_htpasswd() {
  echo "=== No Keycloak detected — using htpasswd identity provider ==="

  # Generate htpasswd file
  HTPASSWD_FILE=$(mktemp)
  for USER in "${USERS[@]}"; do
    htpasswd -Bb "$HTPASSWD_FILE" "$USER" "$USER_PASSWORD"
  done

  # Create/update the secret
  oc create secret generic htpass-secret \
    --from-file=htpasswd="$HTPASSWD_FILE" \
    -n openshift-config --dry-run=client -o yaml | oc apply -f -

  rm -f "$HTPASSWD_FILE"

  # Ensure OAuth is configured with htpasswd
  oc apply -f "$REPO_DIR/UsersGroups/htpasswd.yaml"

  # Create OpenShift groups (needed when not using Keycloak group sync)
  echo "Creating OpenShift groups..."
  oc apply -f "$REPO_DIR/UsersGroups/groups.yaml"

  echo ""
  echo "=== htpasswd setup complete ==="
  echo "Login URL: $(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
  echo "Select 'htpasswd_provider' at login screen"
  echo "All users password: $USER_PASSWORD"
}

# Grant cluster-admin to admin user
grant_admin_role() {
  echo "Granting cluster-admin to admin user..."
  oc adm policy add-cluster-role-to-user cluster-admin admin 2>/dev/null || true
}

# Main
echo "RHACM GitOps Multi-Tenancy Demo — User Setup"
echo "============================================="
echo ""

if detect_keycloak; then
  setup_keycloak
else
  setup_htpasswd
fi

grant_admin_role

echo ""
echo "Users created:"
printf "  %-15s %-20s\n" "USERNAME" "GROUP"
printf "  %-15s %-20s\n" "--------" "-----"
for USER in "${USERS[@]}"; do
  printf "  %-15s %-20s\n" "$USER" "${USER_GROUPS[$USER]}"
done
echo ""
echo "  admin           acm-sre-group (cluster-admin)"
