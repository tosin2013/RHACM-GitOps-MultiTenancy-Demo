# Cluster Provisioning Guide

## Overview

This guide covers provisioning spoke clusters on AWS using RHACM's Hive integration. Each cluster is a Single Node OpenShift (SNO) instance running on `m6i.2xlarge`.

## Prerequisites

- AWS account with sufficient quotas (see checks below)
- ACM AWS credential created (see deployment guide Step 2)
- ClusterImageSet available on the hub (check with `oc get clusterimageset`)

## Pre-Deployment Checks

Run the included script to verify AWS quotas:

```bash
bash cluster-provisioning/pre-deploy-check.sh
```

This checks:
- Elastic IP quota (need 3 per SNO cluster, minimum 6 available)
- vCPU quota for `m6i.2xlarge` instances (8 vCPUs each, 16 total needed)
- ClusterImageSet availability
- Releases any orphaned (unassociated) Elastic IPs

### Manual Quota Check

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
```

## Cluster YAML Structure

Each cluster provisioning file contains:
- `Namespace` — isolated namespace for cluster resources
- `ClusterDeployment` — Hive resource that drives the IPI installation
- `MachinePool` — worker node configuration (0 workers for SNO)
- `Secret (install-config)` — OpenShift installer configuration
- `ManagedCluster` — ACM resource for cluster management (pre-labeled with ClusterSet)
- `KlusterletAddonConfig` — enables ACM addons on the spoke

## Provisioning Steps

### 1. Copy secrets to cluster namespaces

```bash
for NS in blue-cluster red-cluster; do
  oc create namespace $NS --dry-run=client -o yaml | oc apply -f -
  oc create secret generic aws-credentials -n $NS \
    --from-literal=aws_access_key_id="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -d)" \
    --from-literal=aws_secret_access_key="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)" \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic pull-secret -n $NS \
    --from-file=.dockerconfigjson=~/pull-secret.json \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic ${NS}-ssh-private-key -n $NS \
    --from-file=ssh-privatekey=~/.ssh/id_rsa \
    --dry-run=client -o yaml | oc apply -f -
done
```

### 2. Apply ClusterDeployment manifests

```bash
oc apply -f cluster-provisioning/blue-cluster.yaml
oc apply -f cluster-provisioning/red-cluster.yaml
```

### 3. Monitor provisioning

```bash
# Watch deployment status
watch oc get clusterdeployment -A

# Check provisioning logs
oc get pods -n blue-cluster | grep provision
oc logs -n blue-cluster -l hive.openshift.io/cluster-deployment-name=blue-cluster -f
```

Provisioning takes approximately 30-45 minutes per cluster.

### 4. Verify cluster availability

```bash
oc get managedclusters
# Both clusters should show JOINED=True, AVAILABLE=True
```

## Customizing Cluster Configuration

### Changing instance type

Edit the `install-config.yaml` section in each cluster YAML:

```yaml
controlPlane:
  platform:
    aws:
      type: m6i.4xlarge  # Change instance type here
```

### Changing region

Update both the `ClusterDeployment.spec.platform.aws.region` and the `install-config.yaml` platform section.

### Changing OpenShift version

Update the `imageSetRef`:

```yaml
provisioning:
  imageSetRef:
    name: img4.21.20-multi-appsub  # Change to desired version
```

List available versions: `oc get clusterimageset | grep multi-appsub | sort -V`

## Cleanup

To destroy provisioned clusters:

```bash
oc delete clusterdeployment blue-cluster -n blue-cluster
oc delete clusterdeployment red-cluster -n red-cluster
# Wait for AWS resources to be cleaned up, then:
oc delete namespace blue-cluster red-cluster
```
