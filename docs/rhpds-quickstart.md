# RHPDS Quickstart: One-Command Deployment

Deploy the full RHACM GitOps Multi-Tenancy Demo on a Red Hat Demo Platform (RHDP) environment with a single command.

## What You Get from RHDP

When you order the [Advanced Cluster Management for Kubernetes Demo](https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/published.ocp4-acm-demo.prod) catalog item, you receive:

- 1 Hub cluster with **RHACM 2.15** pre-installed
- `open-cluster-management` namespace configured
- Keycloak (RHBK) running in the `keycloak` namespace
- AWS credentials available for spoke cluster provisioning
- Domain pattern: `*.apps.cluster-<GUID>.dynamic2.redhatworkshops.io`

## One-Command Deployment

```bash
# 1. Login to your hub cluster (credentials from RHDP provisioning email)
oc login --token=<token> --server=https://api.cluster-<GUID>.dynamic2.redhatworkshops.io:6443

# 2. Clone the repo and run
git clone https://github.com/tosin2013/RHACM-GitOps-MultiTenancy-Demo.git
cd RHACM-GitOps-MultiTenancy-Demo
git checkout fleetdev

# 3. Deploy everything
bash scripts/deploy-demo.sh
```

The script will auto-detect:
- Your hub's base domain (from the cluster ingress config)
- Keycloak presence (configures OIDC users if found)
- AWS credentials (from ACM secret)
- Pull secret location (`~/pull-secret.json`)

## Common Options

```bash
# Skip spoke cluster provisioning (if clusters already exist)
bash scripts/deploy-demo.sh --skip-clusters

# Skip user setup (if users already configured)
bash scripts/deploy-demo.sh --skip-users

# Preview without executing
bash scripts/deploy-demo.sh --dry-run

# Custom user password
bash scripts/deploy-demo.sh --password 'MySecurePass123!'

# Custom pull-secret location
bash scripts/deploy-demo.sh --pull-secret /path/to/pull-secret.json

# Override the auto-detected base domain for spoke provisioning
bash scripts/deploy-demo.sh --base-domain sandbox1234.opentlc.com
```

### Base Domain Detection

The script auto-detects the base domain by stripping the hub's cluster-specific prefix:
- Hub ingress: `apps.cluster-xb7dm.dynamic2.redhatworkshops.io`
- Detected base domain: `dynamic2.redhatworkshops.io`
- Spoke clusters will be: `blue-cluster.dynamic2.redhatworkshops.io`

The script will prompt you to confirm this is correct before provisioning. If it detects
the wrong domain, use `--base-domain` to override it explicitly.

## Expected Timeline

| Phase | Duration | What Happens |
|-------|----------|--------------|
| Environment Detection | ~5 seconds | Discovers domain, Keycloak, AWS creds |
| Foundation (Users + GitOps) | ~2 minutes | Configures auth, installs GitOps operator |
| Principal Deployment | ~3 minutes | Deploys fleet-argocd Principal instance |
| Spoke Cluster Provisioning | **30-45 minutes** | Provisions 2 SNO clusters via Hive on AWS |
| Agent TLS + Deployment | ~5 minutes | Sets up mTLS via cert-manager, deploys agents |
| Applications | ~2 minutes | Deploys ApplicationSets, registers clusters |

**Total: ~45-55 minutes** (dominated by cluster provisioning)

## Verifying Success

After deployment completes, the script prints the ArgoCD URL and credentials. You can also verify manually:

```bash
# Check managed clusters are available
oc get managedcluster
# Expected: blue-cluster and red-cluster show AVAILABLE=True

# Check ArgoCD applications are synced
oc get applications.argoproj.io -n fleet-gitops
# Expected: All apps show Synced/Healthy

# Get ArgoCD UI URL
oc get route fleet-argocd-server -n fleet-gitops -o jsonpath='{.spec.host}'
```

### ArgoCD UI Access

| User | Password | Sees |
|------|----------|------|
| admin | (shown by script) | All applications |
| acmsre1 | `openshift` (or custom) | All applications (platform admin) |
| bluesre1 | `openshift` (or custom) | Blue team apps only |
| redsre1 | `openshift` (or custom) | Red team apps only |

## RHPDS-Specific Considerations

### Elastic IP Limits

AWS imposes a default limit of 5 Elastic IPs per region. Each SNO spoke cluster requires 3 EIPs (one per AZ for NAT gateways). The pre-deployment check (`cluster-provisioning/pre-deploy-check.sh`) validates this and offers to request a quota increase.

If you encounter `AddressLimitExceeded` errors:
```bash
# Run pre-deploy check to release orphaned EIPs
bash cluster-provisioning/pre-deploy-check.sh
```

### Environment Lifetime

RHDP demo environments have a limited TTL (typically 4-8 hours for demos, longer for workshops). Plan accordingly — spoke cluster provisioning alone takes 30-45 minutes.

### Domain Structure

The RHDP environment uses:
- **Hub API**: `https://api.cluster-<GUID>.dynamic2.redhatworkshops.io:6443`
- **Hub Console**: `https://console-openshift-console.apps.cluster-<GUID>.dynamic2.redhatworkshops.io`
- **ArgoCD UI**: `https://fleet-argocd-server-fleet-gitops.apps.cluster-<GUID>.dynamic2.redhatworkshops.io`
- **Spoke APIs**: `https://api.blue-cluster.<base-domain>:6443`

### Pull Secret

If `~/pull-secret.json` doesn't exist, download it from:
https://console.redhat.com/openshift/install/pull-secret

```bash
# Place it in your home directory
mv ~/Downloads/pull-secret.json ~/pull-secret.json
```

### AWS Credentials

AWS credentials are typically pre-configured in the ACM credential secret. The deploy script reads them automatically. If they're not present:

```bash
oc create namespace aws-credentials --dry-run=client -o yaml | oc apply -f -
oc create secret generic aws-credentials -n aws-credentials \
  --from-literal=aws_access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
oc label secret aws-credentials -n aws-credentials \
  cluster.open-cluster-management.io/type=aws \
  cluster.open-cluster-management.io/credentials=""
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Not logged into OpenShift cluster` | Missing `oc login` | Run `oc login` with token from RHDP email |
| `AddressLimitExceeded` | AWS EIP quota hit | Run `pre-deploy-check.sh`, release orphans |
| GitOps operator not ready after 5 min | OLM slow on SNO | Wait, or check `oc get csv -n openshift-gitops` |
| Spoke clusters stuck provisioning | DNS/VPC issues | Check `oc get clusterdeployment -A -o yaml` |
| Agent can't connect to Principal | TLS or route issue | See [troubleshooting.md](troubleshooting.md) |

For detailed troubleshooting, see [docs/troubleshooting.md](troubleshooting.md).

## References

- [ArgoCD Agent Architecture](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html/argo_cd_agent_architecture/argocd-agent-architecture)
- [ArgoCD Agent Installation](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.20/html-single/argo_cd_agent_installation/)
- [RHACM Workshop](https://tosin2013.github.io/rhacm-workshop/modules/01-installation.html)
- [Full Deployment Guide](deployment-guide.md)
