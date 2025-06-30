#!/bin/bash
# 04-init-cluster.sh
# 마스터 노드에서 클러스터 초기화 (마스터 노드에서만 실행)

set -e

echo "=== Kubernetes 클러스터 초기화 시작 ==="

# 마스터 노드 확인
NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
if [ "$NODE_IP" != "10.10.10.99" ]; then
    echo "❌ 이 스크립트는 마스터 노드(10.10.10.99)에서만 실행해야 합니다."
    echo "현재 노드 IP: $NODE_IP"
    exit 1
fi

echo "✅ 마스터 노드 확인: $NODE_IP"

# kubeadm 설정 파일 생성
echo "kubeadm 설정 파일 생성 중..."
cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.10.10.99"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.0
clusterName: "k8s-cluster"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
apiServer:
  bindPort: 6443
  certSANs:
  - "10.10.10.99"
  - "dover-rhel94-master"
  - "k8s-master"
  - "localhost"
  - "127.0.0.1"
controllerManager: {}
scheduler: {}
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: false
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
serverTLSBootstrap: true
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
EOF

echo "✅ kubeadm 설정 파일 생성 완료"

# 필요한 이미지 확인
echo "필요한 이미지 목록 확인..."
kubeadm config images list --config=/root/kubeadm-config.yaml

# 이미지 사전 다운로드 (온라인 환경에서만)
if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "온라인 환경 - 이미지 사전 다운로드 중..."
    kubeadm config images pull --config=/root/kubeadm-config.yaml
else
    echo "오프라인 환경 - 이미지 사전 다운로드 생략"
fi

# 클러스터 초기화
echo "클러스터 초기화 중... (시간이 걸릴 수 있습니다)"
sudo kubeadm init \
  --config=/root/kubeadm-config.yaml \
  --ignore-preflight-errors=Mem,FileExisting-socat,FileExisting-conntrack \
  --upload-certs

# 초기화 성공 확인
if [ $? -ne 0 ]; then
    echo "❌ 클러스터 초기화 실패"
    exit 1
fi

echo "✅ 클러스터 초기화 성공!"

# kubectl 설정
echo "kubectl 설정 중..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 일반 사용자용 설정 (chris 사용자)
if [ -d "/home/chris" ]; then
    echo "chris 사용자용 kubectl 설정..."
    sudo mkdir -p /home/chris/.kube
    sudo cp -i /etc/kubernetes/admin.conf /home/chris/.kube/config
    sudo chown chris:chris /home/chris/.kube/config
fi

# 워커 노드 조인 명령어 생성
echo "워커 노드 조인 명령어 생성 중..."
kubeadm token create --print-join-command > /root/worker-join-command.sh
chmod +x /root/worker-join-command.sh

echo "워커 노드 조인 명령어:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat /root/worker-join-command.sh
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 클러스터 상태 확인
echo "초기 클러스터 상태 확인..."
sleep 10
kubectl get nodes
kubectl get pods -n kube-system

# CNI 설치 (Flannel)
echo "CNI (Flannel) 설치 중..."
wget -O /root/kube-flannel.yml https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 폐쇄망 환경의 경우 이미지 경로 수정 필요
# sed -i "s|docker.io/flannel/flannel:|INTERNAL_REGISTRY:5000/flannel/flannel:|g" /root/kube-flannel.yml

kubectl apply -f /root/kube-flannel.yml

echo "CNI 설치 완료. Flannel Pod 시작 대기 중..."
sleep 15

# 마스터 노드 상태 재확인
echo "마스터 노드 상태 확인..."
kubectl get nodes
kubectl get pods -n kube-system
kubectl get pods -n kube-flannel

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        클러스터 초기화 완료                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 다음 단계:"
echo "1. 각 워커 노드에서 05-join-workers.sh 실행"
echo "2. 모든 노드 조인 완료 후 06-install-apps.sh 실행"
echo ""
echo "🔗 워커 노드 조인 명령어: /root/worker-join-command.sh"
echo "📂 kubeconfig 파일: ~/.kube/config"
echo ""
echo "💡 클러스터 상태 확인: kubectl get nodes"
