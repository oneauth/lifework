#!/bin/bash
# 01-system-setup.sh
# RHEL 9.4 시스템 기본 설정 (모든 노드에서 실행)

set -e

echo "=== RHEL 9.4 시스템 기본 설정 시작 ==="

# 현재 노드 IP 확인
NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
echo "현재 노드 IP: $NODE_IP"

# 호스트명 설정 확인
case $NODE_IP in
    "10.10.10.99")
        HOSTNAME="dover-rhel94-master"
        ;;
    "10.10.10.100")
        HOSTNAME="dover-rhel94-worker1"
        ;;
    "10.10.10.103")
        HOSTNAME="dover-rhel94-worker2"
        ;;
    "10.10.10.105")
        HOSTNAME="dover-rhel94-worker3"
        ;;
    *)
        echo "알 수 없는 IP 주소: $NODE_IP"
        read -p "호스트명을 입력하세요: " HOSTNAME
        ;;
esac

echo "호스트명 설정: $HOSTNAME"
sudo hostnamectl set-hostname $HOSTNAME

# /etc/hosts 설정
echo "hosts 파일 설정 중..."
sudo tee -a /etc/hosts <<EOF
10.10.10.99  dover-rhel94-master k8s-master
10.10.10.100 dover-rhel94-worker1 k8s-worker1
10.10.10.103 dover-rhel94-worker2 k8s-worker2
10.10.10.105 dover-rhel94-worker3 k8s-worker3
EOF

# RHEL 저장소 문제 해결
echo "RHEL 저장소 설정 중..."
sudo systemctl disable rhsmcertd 2>/dev/null || true
sudo systemctl stop rhsmcertd 2>/dev/null || true

# 기존 저장소 백업
sudo mkdir -p /etc/yum.repos.d/backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

# CentOS Stream 저장소 설정 (테스트용)
sudo tee /etc/yum.repos.d/centos-stream.repo <<EOF
[centos-stream-baseos]
name=CentOS Stream 9 - BaseOS
baseurl=http://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/
enabled=1
gpgcheck=0

[centos-stream-appstream]
name=CentOS Stream 9 - AppStream
baseurl=http://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/
enabled=1
gpgcheck=0
EOF

# 저장소 캐시 갱신
sudo dnf clean all && sudo dnf makecache

# SELinux 설정
echo "SELinux 설정 중..."
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# swap 비활성화
echo "swap 비활성화 중..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 방화벽 설정 (테스트 환경용 비활성화)
echo "방화벽 비활성화 중..."
sudo systemctl stop firewalld 2>/dev/null || true
sudo systemctl disable firewalld 2>/dev/null || true

# 커널 모듈 설정
echo "커널 모듈 설정 중..."
sudo modprobe br_netfilter overlay
echo -e 'br_netfilter\noverlay' | sudo tee /etc/modules-load.d/k8s.conf

# 네트워크 설정
echo "네트워크 설정 중..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# 필수 패키지 설치 시도
echo "필수 패키지 설치 중..."
sudo dnf install -y curl wget git vim socat conntrack-tools || echo "일부 패키지 설치 실패 - 수동 설치 필요"

# 필수 디렉토리 생성
echo "필수 디렉토리 생성 중..."
sudo mkdir -p /etc/kubernetes/{pki,manifests}
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /var/lib/kubeadm
sudo mkdir -p /var/lib/etcd
sudo mkdir -p /etc/cni/net.d
sudo mkdir -p /opt/cni/bin

echo "=== 시스템 기본 설정 완료 ==="
echo "다음 단계: 02-install-containerd.sh 실행"
