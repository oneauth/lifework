# RHEL 9.4 Kubernetes 설치 가이드

## 개요

이 가이드는 RHEL 9.4에서 Kubernetes 1.29와 관련 애플리케이션들을 오프라인 환경에서 설치하는 방법을 제공합니다.

### 설치 구성 요소
- **Kubernetes 1.29** (containerd + podman, Docker 없음)
- **Rancher UI** - Kubernetes 관리 웹 인터페이스
- **AWX** - Ansible Tower 오픈소스 버전
- **Apache Kafka** - 메시지 브로커
- **Harbor** - 컨테이너 레지스트리

### 환경 요구사항
- RHEL 9.4
- 최소 4GB RAM, 2 CPU 코어
- 50GB 이상 디스크 공간
- 프록시 레지스트리 접근 가능
- 관리자 권한

---

## 1. 시스템 기본 설정

### 1.1 시스템 업데이트 및 패키지 설치

```bash
# 시스템 업데이트
sudo dnf update -y

# 필요한 패키지 설치
sudo dnf install -y curl wget git vim tar gzip
```

### 1.2 SELinux 설정

```bash
# SELinux 비활성화 (권장)
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
```

### 1.3 방화벽 설정

```bash
# Kubernetes 관련 포트 개방
sudo firewall-cmd --permanent --add-port=6443/tcp    # K8s API
sudo firewall-cmd --permanent --add-port=80/tcp      # HTTP
sudo firewall-cmd --permanent --add-port=443/tcp     # HTTPS
sudo firewall-cmd --permanent --add-port=2379-2380/tcp # etcd
sudo firewall-cmd --permanent --add-port=10250/tcp   # kubelet
sudo firewall-cmd --permanent --add-port=10251/tcp   # kube-scheduler
sudo firewall-cmd --permanent --add-port=10252/tcp   # kube-controller
sudo firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort range
sudo firewall-cmd --reload
```

### 1.4 swap 비활성화

```bash
# swap 비활성화
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 1.5 커널 모듈 및 네트워크 설정

```bash
# br_netfilter 모듈 로드
sudo modprobe br_netfilter
echo 'br_netfilter' | sudo tee /etc/modules-load.d/k8s.conf

# 네트워크 설정
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
```

---

## 2. 컨테이너 런타임 설정

### 2.1 Containerd 설치

```bash
# containerd 설치
sudo dnf install -y containerd

# containerd 설정 디렉토리 생성
sudo mkdir -p /etc/containerd

# 기본 설정 파일 생성
containerd config default | sudo tee /etc/containerd/config.toml

# SystemdCgroup 활성화
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

### 2.2 프록시 레지스트리 설정

**⚠️ 중요: `YOUR_PROXY_REGISTRY` 부분을 실제 프록시 레지스트리 주소로 변경하세요**

```bash
# containerd 프록시 레지스트리 설정 추가
cat <<EOF | sudo tee -a /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://YOUR_PROXY_REGISTRY/v2/docker.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
      endpoint = ["https://YOUR_PROXY_REGISTRY/v2/k8s.gcr.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["https://YOUR_PROXY_REGISTRY/v2/registry.k8s.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["https://YOUR_PROXY_REGISTRY/v2/quay.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["https://YOUR_PROXY_REGISTRY/v2/gcr.io"]
EOF

# containerd 서비스 재시작
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 2.3 Podman 설치 및 설정

```bash
# podman 설치
sudo dnf install -y podman

# podman 레지스트리 설정
cat <<EOF | sudo tee /etc/containers/registries.conf
unqualified-search-registries = ["docker.io", "quay.io"]

[[registry]]
prefix = "docker.io"
location = "YOUR_PROXY_REGISTRY/v2/docker.io"

[[registry]]
prefix = "k8s.gcr.io"
location = "YOUR_PROXY_REGISTRY/v2/k8s.gcr.io"

[[registry]]
prefix = "registry.k8s.io"
location = "YOUR_PROXY_REGISTRY/v2/registry.k8s.io"

[[registry]]
prefix = "quay.io"
location = "YOUR_PROXY_REGISTRY/v2/quay.io"

[[registry]]
prefix = "gcr.io"
location = "YOUR_PROXY_REGISTRY/v2/gcr.io"
EOF
```

---

## 3. Kubernetes 설치

### 3.1 Kubernetes 저장소 추가

```bash
# Kubernetes 저장소 설정
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
```

### 3.2 Kubernetes 패키지 설치

```bash
# kubelet, kubeadm, kubectl 설치
sudo dnf install -y kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

### 3.3 kubeadm 설정 파일 생성

**⚠️ 중요: `YOUR_NODE_IP`와 `YOUR_PROXY_REGISTRY`를 실제 값으로 변경하세요**

```bash
# kubeadm 설정 파일 생성
cat <<EOF | sudo tee /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "YOUR_NODE_IP"
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.0
imageRepository: YOUR_PROXY_REGISTRY/registry.k8s.io
networking:
  podSubnet: "10.244.0.0/16"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

### 3.4 클러스터 초기화

```bash
# 클러스터 초기화
sudo kubeadm init --config=/root/kubeadm-config.yaml

# kubectl 설정 (root 사용자)
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 일반 사용자를 위한 설정
sudo mkdir -p /home/$USER/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/$USER/.kube/config
sudo chown $USER:$USER /home/$USER/.kube/config

# 단일 노드 클러스터를 위한 taint 제거
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
```

### 3.5 CNI 플러그인 설치 (Flannel)

```bash
# Flannel 매니페스트 다운로드
wget -O kube-flannel.yml https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 이미지 경로를 프록시 레지스트리로 변경
sed -i "s|docker.io/flannel/flannel:|YOUR_PROXY_REGISTRY/flannel/flannel:|g" kube-flannel.yml
sed -i "s|docker.io/flannel/flannel-cni-plugin:|YOUR_PROXY_REGISTRY/flannel/flannel-cni-plugin:|g" kube-flannel.yml

# Flannel 설치
kubectl apply -f kube-flannel.yml
```

### 3.6 Helm 설치

```bash
# Helm 설치 스크립트 다운로드 및 실행
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

---

## 4. Rancher UI 설치

### 4.1 cert-manager 설치

```bash
# cert-manager 네임스페이스 생성
kubectl create namespace cert-manager

# cert-manager CRDs 설치
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml

# cert-manager Helm 저장소 추가
helm repo add jetstack https://charts.jetstack.io
helm repo update

# cert-manager 설치 (프록시 레지스트리 이미지 사용)
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.13.0 \
  --set image.repository=YOUR_PROXY_REGISTRY/quay.io/jetstack/cert-manager-controller \
  --set webhook.image.repository=YOUR_PROXY_REGISTRY/quay.io/jetstack/cert-manager-webhook \
  --set cainjector.image.repository=YOUR_PROXY_REGISTRY/quay.io/jetstack/cert-manager-cainjector \
  --set startupapicheck.image.repository=YOUR_PROXY_REGISTRY/quay.io/jetstack/cert-manager-ctl
```

### 4.2 Rancher 설치

**⚠️ 중요: `rancher.local`을 실제 사용할 호스트명으로 변경하세요**

```bash
# Rancher 네임스페이스 생성
kubectl create namespace cattle-system

# Rancher Helm 저장소 추가
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

# Rancher 설치
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher.local \
  --set replicas=1 \
  --set rancherImage=YOUR_PROXY_REGISTRY/rancher/rancher \
  --set systemDefaultRegistry=YOUR_PROXY_REGISTRY \
  --set useBundledSystemChart=true
```

### 4.3 Rancher 초기 비밀번호 확인

```bash
# 초기 비밀번호 확인
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}'
```

---

## 5. AWX 설치

### 5.1 AWX 네임스페이스 생성

```bash
kubectl create namespace awx
```

### 5.2 AWX Operator 설치

```bash
# AWX Operator 매니페스트 생성
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: awx-operator
  namespace: awx
  labels:
    app.kubernetes.io/name: awx-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      name: awx-operator
  template:
    metadata:
      labels:
        name: awx-operator
    spec:
      serviceAccountName: awx-operator
      containers:
      - name: awx-operator
        image: YOUR_PROXY_REGISTRY/ansible/awx-operator:latest
        command:
        - /manager
        env:
        - name: WATCH_NAMESPACE
          value: awx
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: OPERATOR_NAME
          value: awx-operator
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: awx-operator
  namespace: awx
EOF
```

### 5.3 AWX 인스턴스 생성

```bash
# AWX 인스턴스 생성
cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  service_type: nodeport
  nodeport_port: 30080
  image: YOUR_PROXY_REGISTRY/ansible/awx
  image_version: latest
  postgres_image: YOUR_PROXY_REGISTRY/postgres:13
  redis_image: YOUR_PROXY_REGISTRY/redis:7
EOF
```

### 5.4 AWX 관리자 비밀번호 확인

```bash
# 관리자 비밀번호 확인 (설치 완료 후)
kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx | base64 --decode
```

---

## 6. Apache Kafka 설치

### 6.1 Kafka 네임스페이스 생성

```bash
kubectl create namespace kafka
```

### 6.2 Strimzi Operator 설치

```bash
# Strimzi Operator 설치
kubectl apply -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# 또는 오프라인 환경의 경우 매니페스트를 수정하여 프록시 레지스트리 이미지 사용
```

### 6.3 Kafka 클러스터 생성

```bash
# Kafka 클러스터 매니페스트 생성
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
spec:
  kafka:
    version: 3.6.0
    replicas: 1
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 9094
        type: nodeport
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      log.message.format.version: "3.6"
      inter.broker.protocol.version: "3.6"
    storage:
      type: jbod
      volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        deleteClaim: false
  zookeeper:
    replicas: 1
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: false
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF
```

---

## 7. Harbor 설치

### 7.1 Harbor 네임스페이스 생성

```bash
kubectl create namespace harbor
```

### 7.2 Harbor Helm 저장소 추가

```bash
# Harbor Helm 저장소 추가
helm repo add harbor https://helm.goharbor.io
helm repo update
```

### 7.3 Harbor Values 파일 생성

**⚠️ 중요: `YOUR_NODE_IP`와 비밀번호를 실제 값으로 변경하세요**

```bash
# Harbor values 파일 생성
cat <<EOF > harbor-values.yaml
expose:
  type: nodePort
  nodePort:
    ports:
      http:
        nodePort: 30002
      https:
        nodePort: 30003

externalURL: http://YOUR_NODE_IP:30002
harborAdminPassword: "Harbor12345"

# 프록시 레지스트리 이미지 설정
core:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/harbor-core
    tag: v2.8.0

portal:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/harbor-portal
    tag: v2.8.0

jobservice:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/harbor-jobservice
    tag: v2.8.0

registry:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/registry-photon
    tag: v2.8.0

registryctl:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/harbor-registryctl
    tag: v2.8.0

database:
  internal:
    image:
      repository: YOUR_PROXY_REGISTRY/goharbor/harbor-db
      tag: v2.8.0

redis:
  internal:
    image:
      repository: YOUR_PROXY_REGISTRY/goharbor/redis-photon
      tag: v2.8.0

trivy:
  image:
    repository: YOUR_PROXY_REGISTRY/goharbor/trivy-adapter-photon
    tag: v2.8.0
EOF
```

### 7.4 Harbor 설치

```bash
# Harbor 설치
helm install harbor harbor/harbor \
  --namespace harbor \
  --values harbor-values.yaml
```

---

## 8. 설치 검증

### 8.1 클러스터 상태 확인

```bash
# 노드 상태 확인
kubectl get nodes

# 모든 Pod 상태 확인
kubectl get pods --all-namespaces

# 서비스 상태 확인
kubectl get svc --all-namespaces
```

### 8.2 각 애플리케이션 상태 확인

```bash
# Rancher 상태
kubectl get pods -n cattle-system

# AWX 상태
kubectl get pods -n awx

# Kafka 상태
kubectl get pods -n kafka

# Harbor 상태
kubectl get pods -n harbor
```

---

## 9. 접속 정보

### 애플리케이션 접속 URLs

- **Rancher UI**: `https://rancher.local` (hosts 파일 설정 필요)
- **AWX**: `http://YOUR_NODE_IP:30080`
- **Harbor**: `http://YOUR_NODE_IP:30002`
- **Kafka**: `my-cluster-kafka-bootstrap.kafka.svc:9092` (클러스터 내부)

### 기본 계정 정보

#### Rancher
- 초기 비밀번호는 설치 후 kubectl 명령으로 확인

#### AWX
- 사용자명: `admin`
- 비밀번호: kubectl 명령으로 확인

#### Harbor
- 사용자명: `admin`
- 비밀번호: `Harbor12345` (또는 설정한 비밀번호)

---

## 10. 문제 해결

### 일반적인 문제들

#### Pod가 Pending 상태인 경우
```bash
# 이벤트 확인
kubectl describe pod <pod-name> -n <namespace>

# 노드 리소스 확인
kubectl describe nodes
```

#### 이미지 Pull 실패
```bash
# containerd 설정 확인
sudo cat /etc/containerd/config.toml

# containerd 재시작
sudo systemctl restart containerd
```

#### 네트워크 연결 문제
```bash
# CNI 플러그인 상태 확인
kubectl get pods -n kube-system | grep flannel

# 네트워크 설정 확인
sudo sysctl net.bridge.bridge-nf-call-iptables
```

### 로그 확인 방법

```bash
# 특정 Pod 로그 확인
kubectl logs <pod-name> -n <namespace>

# 이전 컨테이너 로그 확인
kubectl logs <pod-name> -n <namespace> --previous

# 시스템 로그 확인
journalctl -u kubelet
journalctl -u containerd
```

---

## 11. 추가 설정

### 11.1 Ingress Controller 설치 (선택사항)

```bash
# NGINX Ingress Controller 설치
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
```

### 11.2 Persistent Volume 설정

```bash
# 로컬 스토리지 사용 예시
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/data
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - YOUR_NODE_NAME
EOF
```

### 11.3 백업 스크립트

```bash
#!/bin/bash
# backup-cluster.sh

BACKUP_DIR="/backup/kubernetes/$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR

# etcd 백업
sudo ETCDCTL_API=3 etcdctl snapshot save $BACKUP_DIR/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 설정 파일 백업
cp -r /etc/kubernetes $BACKUP_DIR/
cp /etc/containerd/config.toml $BACKUP_DIR/

echo "백업 완료: $BACKUP_DIR"
```

---

## 참고 자료

- [Kubernetes 공식 문서](https://kubernetes.io/docs/)
- [Rancher 설치 가이드](https://rancher.com/docs/rancher/v2.6/en/installation/)
- [AWX Operator 문서](https://ansible.readthedocs.io/projects/awx-operator/)
- [Strimzi Kafka 문서](https://strimzi.io/docs/)
- [Harbor 설치 가이드](https://goharbor.io/docs/)

---

**⚠️ 주의사항**
1. 모든 `YOUR_PROXY_REGISTRY`, `YOUR_NODE_IP` 등은 실제 환경에 맞게 변경해야 합니다
2. 프로덕션 환경에서는 보안 설정을 강화하세요
3. 정기적인 백업을 설정하세요
4. 각 애플리케이션의 공식 문서를 참조하여 세부 설정을 조정하세요