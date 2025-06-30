#!/bin/bash
# 02-install-containerd.sh
# Containerd 및 관련 도구 설치 (모든 노드에서 실행)

set -e

echo "=== Containerd 설치 시작 ==="

# 작업 디렉토리 생성
WORK_DIR="$HOME/containerd-install"
mkdir -p $WORK_DIR
cd $WORK_DIR

# 버전 설정
CONTAINERD_VERSION="1.7.8"
RUNC_VERSION="1.1.9"
CNI_VERSION="1.3.0"
CRICTL_VERSION="1.29.0"

echo "버전 정보:"
echo "  Containerd: $CONTAINERD_VERSION"
echo "  runc: $RUNC_VERSION"
echo "  CNI plugins: $CNI_VERSION"
echo "  crictl: $CRICTL_VERSION"

# 바이너리 다운로드 (온라인 환경에서만)
download_binaries() {
    echo "바이너리 다운로드 중..."
    
    # containerd
    wget -O containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz \
        https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
    
    # runc
    wget -O runc.amd64 \
        https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
    
    # CNI plugins
    wget -O cni-plugins-linux-amd64-v${CNI_VERSION}.tgz \
        https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
    
    # crictl
    wget -O crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz \
        https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz
}

# 오프라인 설치 함수
install_binaries() {
    echo "바이너리 설치 중..."
    
    # containerd 설치
    if [ -f "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" ]; then
        sudo tar Cxzvf /usr/local containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
        echo "✅ containerd 설치 완료"
    else
        echo "❌ containerd 파일을 찾을 수 없습니다"
        return 1
    fi
    
    # runc 설치
    if [ -f "runc.amd64" ]; then
        sudo install -m 755 runc.amd64 /usr/local/sbin/runc
        echo "✅ runc 설치 완료"
    else
        echo "❌ runc 파일을 찾을 수 없습니다"
        return 1
    fi
    
    # CNI plugins 설치
    if [ -f "cni-plugins-linux-amd64-v${CNI_VERSION}.tgz" ]; then
        sudo mkdir -p /opt/cni/bin
        sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${CNI_VERSION}.tgz
        echo "✅ CNI plugins 설치 완료"
    else
        echo "❌ CNI plugins 파일을 찾을 수 없습니다"
        return 1
    fi
    
    # crictl 설치
    if [ -f "crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz" ]; then
        tar zxvf crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz
        sudo install -m 755 crictl /usr/local/bin/crictl
        echo "✅ crictl 설치 완료"
    else
        echo "❌ crictl 파일을 찾을 수 없습니다"
        return 1
    fi
    
    # 실행 권한 설정
    sudo chmod +x /usr/local/bin/containerd*
    sudo chmod +x /usr/local/sbin/runc
    sudo chmod +x /usr/local/bin/crictl
}

# 온라인 환경 확인
if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "온라인 환경 감지 - 바이너리 다운로드 중..."
    download_binaries
fi

# 바이너리 설치
install_binaries

# systemd 서비스 파일 생성
echo "systemd 서비스 파일 생성 중..."
sudo tee /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# containerd 설정 파일 생성
echo "containerd 설정 파일 생성 중..."
sudo mkdir -p /etc/containerd
sudo /usr/local/bin/containerd config default | sudo tee /etc/containerd/config.toml

# SystemdCgroup 활성화
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# crictl 설정 파일 생성
echo "crictl 설정 파일 생성 중..."
sudo tee /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 2
debug: false
pull-image-on-create: false
EOF

# 서비스 시작
echo "containerd 서비스 시작 중..."
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

# 설치 확인
echo "설치 확인 중..."
sleep 3

# 버전 확인
echo "설치된 버전:"
/usr/local/bin/containerd --version
/usr/local/sbin/runc --version | head -1
/usr/local/bin/crictl --version

# 서비스 상태 확인
sudo systemctl status containerd --no-pager

# crictl 연결 테스트
echo "crictl 연결 테스트:"
sudo crictl version

echo "=== Containerd 설치 완료 ==="
echo "다음 단계: 03-install-kubernetes.sh 실행"
