---
apiVersion: v1
kind: Namespace
metadata:
  name: blue-cluster
---
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: blue-cluster
  namespace: blue-cluster
  labels:
    cloud: AWS
    region: us-east-2
    vendor: OpenShift
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: blue-cluster
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
      name: blue-cluster-install-config
    sshPrivateKeySecretRef:
      name: blue-cluster-ssh-private-key
    imageSetRef:
      name: ${CLUSTER_IMAGE_SET:-img4.21.20-multi-appsub}
  pullSecretRef:
    name: pull-secret
---
apiVersion: hive.openshift.io/v1
kind: MachinePool
metadata:
  name: blue-cluster-worker
  namespace: blue-cluster
spec:
  clusterDeploymentRef:
    name: blue-cluster
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
  name: blue-cluster-install-config
  namespace: blue-cluster
type: Opaque
stringData:
  install-config.yaml: |
    apiVersion: v1
    metadata:
      name: blue-cluster
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
  name: blue-cluster
  labels:
    cloud: Amazon
    region: us-east-2
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: blueclusterset
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: blue-cluster
  namespace: blue-cluster
spec:
  clusterName: blue-cluster
  clusterNamespace: blue-cluster
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
