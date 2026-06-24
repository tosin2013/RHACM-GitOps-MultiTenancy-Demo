---
apiVersion: v1
kind: Namespace
metadata:
  name: red-cluster
---
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: red-cluster
  namespace: red-cluster
  labels:
    cloud: AWS
    region: us-east-2
    vendor: OpenShift
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: red-cluster
  controlPlaneConfig:
    servingCertificates: {}
  installAttemptsLimit: 1
  installed: false
  platform:
    aws:
      credentialsSecretRef:
        name: aws-credentials
      region: us-east-2
  provisioning:
    installConfigSecretRef:
      name: red-cluster-install-config
    sshPrivateKeySecretRef:
      name: red-cluster-ssh-private-key
    imageSetRef:
      name: ${CLUSTER_IMAGE_SET:-img4.21.20-multi-appsub}
  pullSecretRef:
    name: pull-secret
---
apiVersion: hive.openshift.io/v1
kind: MachinePool
metadata:
  name: red-cluster-worker
  namespace: red-cluster
spec:
  clusterDeploymentRef:
    name: red-cluster
  name: worker
  platform:
    aws:
      rootVolume:
        iops: 100
        size: 120
        type: gp3
      type: m6i.2xlarge
  replicas: 0
---
apiVersion: v1
kind: Secret
metadata:
  name: red-cluster-install-config
  namespace: red-cluster
type: Opaque
stringData:
  install-config.yaml: |
    apiVersion: v1
    metadata:
      name: red-cluster
    baseDomain: ${BASE_DOMAIN}
    controlPlane:
      architecture: amd64
      hyperthreading: Enabled
      name: master
      replicas: 1
      platform:
        aws:
          type: m6i.2xlarge
          rootVolume:
            iops: 4000
            size: 120
            type: io1
    compute:
    - architecture: amd64
      hyperthreading: Enabled
      name: worker
      replicas: 0
      platform:
        aws:
          type: m6i.2xlarge
          rootVolume:
            iops: 2000
            size: 120
            type: io1
    networking:
      networkType: OVNKubernetes
      clusterNetwork:
      - cidr: 10.128.0.0/14
        hostPrefix: 23
      machineNetwork:
      - cidr: 10.0.0.0/16
      serviceNetwork:
      - 172.30.0.0/16
    platform:
      aws:
        region: us-east-2
    pullSecret: ""
    sshKey: "${SSH_PUBLIC_KEY}"
---
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: red-cluster
  labels:
    cloud: Amazon
    region: us-east-2
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: redclusterset
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: red-cluster
  namespace: red-cluster
spec:
  clusterName: red-cluster
  clusterNamespace: red-cluster
  clusterLabels:
    cloud: Amazon
    vendor: OpenShift
  applicationManager:
    enabled: true
  certPolicyController:
    enabled: true
  iamPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
