#!/bin/bash
# 03-install-kubernetes.sh
# Kubernetes 바이너리 설치 및 설정 (모든 노드에서 실행)

set -e

echo "=== Kubernetes 설치 시작 ==="

# 작업 디렉토리 생성
WORK_DIR="$HOME/k8s-install"
mkdir -p $WORK_DIR
cd $WORK_DIR

# 버전 설정
K8S_VERSION="v1.29.0"

echo "Kubernetes 버전: $K8S_VERSION"

# 바이너리 다운로드 함수
download_k8s_binaries() {
    echo "Kubernetes 바이너리 다운로드 중..."
    
    # kubelet 다운로드
    wget -O kubelet https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet
    
    # kubeadm 다운로드
    wget -O kubeadm https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubeadm
    
    # kubectl 다운로드
    wget -O kubectl https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl
    
    echo "✅ 바이너리 다운로드 완료"
}

# 바이너리 설치 함수
install_k8s_binaries() {
    echo "Kubernetes 바이너리 설치 중..."
    
    # 파일 존재 확인
    for binary in kubelet kubeadm kubectl; do
        if [ ! -f "$binary" ]; then
            echo "❌ $binary 파일을 찾을 수 없습니다"
            return 1
        fi
    done
    
    # 실행 권한 부여
    chmod +x kubelet kubeadm kubectl
    
    # /usr/local/bin으로 이동
    sudo mv kubelet kubeadm kubectl /usr/local/bin/
    
    echo "✅ Kubernetes 바이너리 설치 완료"
}

# 온라인 환경 확인 및 다운로드
if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "온라인 환경 감지 - 바이너리 다운로드 중..."
    download_k8s_binaries
fi

# 바이너리 설치
install_k8s_binaries

# kubelet systemd 서비스 파일 생성
echo "kubelet systemd 서비스 파일 생성 중..."
sudo tee /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# kubelet 드롭인 디렉토리 생성
sudo mkdir -p /etc/systemd/system/kubelet.service.d

# kubeadm 드롭인 파일 생성
echo "kubeadm 드롭인 파일 생성 중..."
sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

# containerd 연동 드롭인 파일 생성
echo "containerd 연동 설정 중..."
sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

# kubelet 환경 변수 파일 생성
echo "kubelet 환경 변수 파일 생성 중..."
sudo tee /etc/default/kubelet <<EOF
# kubelet 추가 설정 (테스트 환경용)
KUBELET_EXTRA_ARGS="--max-pods=110 --node-status-update-frequency=10s --image-gc-high-threshold=85 --image-gc-low-threshold=80"
EOF

# systemd 데몬 리로드 및 서비스 활성화
echo "systemd 설정 중..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet

# kubectl 자동완성 설정
echo "kubectl 자동완성 설정 중..."
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc

# kubeadm 자동완성 설정
kubeadm completion bash | sudo tee /etc/bash_completion.d/kubeadm

# 설치 확인
echo "설치 확인 중..."
echo "설치된 버전:"
/usr/local/bin/kubelet --version
/usr/local/bin/kubeadm version --short
/usr/local/bin/kubectl version --short --client

echo "서비스 상태:"
sudo systemctl status kubelet --no-pager || echo "kubelet은 클러스터 초기화 후 시작됩니다"

# 필요한 이미지 확인 (마스터 노드에서만)
NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
if [ "$NODE_IP" = "10.10.10.99" ]; then
    echo "필요한 Kubernetes 이미지 목록:"
    kubeadm config images list --kubernetes-version=${K8S_VERSION}
fi

echo "=== Kubernetes 설치 완료 ==="
if [ "$NODE_IP" = "10.10.10.99" ]; then
    echo "마스터 노드 - 다음 단계: 04-init-cluster.sh 실행"
else
    echo "워커 노드 - 마스터 노드의 클러스터 초기화 완료 후 05-join-workers.sh 실행"
fi
