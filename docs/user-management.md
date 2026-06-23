# User management

This document describes how authentication and authorization work in the RHACM GitOps Multi-Tenancy Demo.

## Authentication modes

The demo supports two identity provider modes, selected automatically by the setup script:

| Mode | When used | Identity provider |
|------|-----------|-------------------|
| **Keycloak (RHBK)** | Keycloak is running on the cluster | OpenID Connect via `rhbk` provider |
| **htpasswd** | No Keycloak detected | HTPasswd file via `htpasswd_provider` |

## Quick start

```bash
# Set a custom password (default is 'openshift' if not set)
export USER_PASSWORD="your-secure-password"

# Run the setup script
./scripts/setup-users.sh
```

The script auto-detects Keycloak. To force htpasswd mode even when Keycloak is present:

```bash
./scripts/setup-users.sh --force-htpasswd
```

## Setting passwords

**IMPORTANT**: The default password `openshift` is for demo/lab environments only. For any shared or semi-production environment, set a strong password via the `USER_PASSWORD` environment variable before running the script.

```bash
# Option 1: Environment variable
export USER_PASSWORD="$(openssl rand -base64 16)"
./scripts/setup-users.sh

# Option 2: Command-line flag
./scripts/setup-users.sh --password "$(openssl rand -base64 16)"
```

All users receive the same password. This is intentional for demo scenarios where an instructor shares credentials. For production, use Keycloak's user self-registration or federated identity (LDAP, SAML).

## Users and groups

| Username | Group | Role | ArgoCD access |
|----------|-------|------|---------------|
| `admin` | acm-sre-group | cluster-admin | Full fleet visibility |
| `acmsre1` | acm-sre-group | SRE | All applications, all clusters |
| `acmsre2` | acm-sre-group | SRE | All applications, all clusters |
| `bluesre1` | blue-sre-group | Team admin | Blue team apps only |
| `bluesre2` | blue-sre-group | Team admin | Blue team apps only |
| `redsre1` | red-sre-group | Team admin | Red team apps only |
| `redsre2` | red-sre-group | Team admin | Red team apps only |
| `acmviewer1` | acm-viewer-group | Viewer | All apps (read-only) |
| `acmviewer2` | acm-viewer-group | Viewer | All apps (read-only) |
| `blueviewer1` | blue-viewer-group | Viewer | Blue apps (read-only) |
| `blueviewer2` | blue-viewer-group | Viewer | Blue apps (read-only) |
| `redviewer1` | red-viewer-group | Viewer | Red apps (read-only) |
| `redviewer2` | red-viewer-group | Viewer | Red apps (read-only) |

## How group sync works

### Keycloak mode

When using Keycloak, groups are synchronized automatically via the OIDC `groups` claim:

1. Users are assigned to groups in Keycloak (e.g., `blue-sre-group`)
2. The `idp-4-ocp` OIDC client includes a `groups` protocol mapper
3. On login, OpenShift reads the `groups` claim from the ID token
4. OpenShift automatically creates/updates the user's group memberships

No manual OpenShift Group resources are needed in this mode.

### htpasswd mode

When using htpasswd, OpenShift Group resources must be created manually (the script applies `UsersGroups/groups.yaml`). The group assignments are static and managed in Git.

## ArgoCD RBAC mapping

ArgoCD AppProject roles map to OpenShift groups:

```
AppProject: blue-team
  role: admin  -> groups: [blue-sre-group]
  role: readonly -> groups: [blue-viewer-group]

AppProject: red-team
  role: admin  -> groups: [red-sre-group]
  role: readonly -> groups: [red-viewer-group]

AppProject: default (platform)
  role: admin  -> groups: [acm-sre-group]
  role: readonly -> groups: [acm-viewer-group]
```

## Keycloak admin access

If you need to manage users directly in the Keycloak admin console:

```bash
# Get the Keycloak URL
oc get route keycloak -n keycloak -o jsonpath='{.spec.host}'

# Get admin credentials
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret keycloak-initial-admin -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

## Files reference

| File | Purpose |
|------|---------|
| `scripts/setup-users.sh` | Main setup script (auto-detects Keycloak vs htpasswd) |
| `UsersGroups/keycloak-realm.json` | Keycloak realm definition with all users and groups |
| `UsersGroups/oauth-oidc.yaml` | OpenID Connect OAuth provider template |
| `UsersGroups/htpasswd.yaml` | htpasswd OAuth config (fallback mode) |
| `UsersGroups/groups.yaml` | OpenShift Group resources (used in htpasswd mode) |
| `UsersGroups/users.yaml` | OpenShift User resources |

## Security considerations

- Default password `openshift` is for demo environments only
- Always set `USER_PASSWORD` to a strong value in shared environments
- Keycloak credentials (initial-admin secret) should be rotated after first setup
- The OIDC client secret (`JPhsRcVazN`) is embedded in the realm JSON for demo convenience; rotate for production use
- Consider enabling Keycloak user self-service password reset for longer-running environments
