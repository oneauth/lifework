#!/bin/bash
# 05-join-workers.sh
# 워커 노드에서 클러스터 조인 (워커 노드에서만 실행)

set -e

echo "=== 워커 노드 클러스터 조인 시작 ==="

# 워커 노드 확인
NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
case $NODE_IP in
    "10.10.10.100"|"10.10.10.103"|"10.10.10.105")
        echo "✅ 워커 노드 확인: $NODE_IP"
        ;;
    "10.10.10.99")
        echo "❌ 마스터 노드에서는 이 스크립트를 실행하지 마세요."
        exit 1
        ;;
    *)
        echo "⚠️  알 수 없는 노드 IP: $NODE_IP"
        echo "계속 진행하시겠습니까? (y/N)"
        read -n 1 -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        ;;
esac

# 마스터 노드 연결 확인
echo "마스터 노드 연결 확인 중..."
if ping -c 3 10.10.10.99 &>/dev/null; then
    echo "✅ 마스터 노드 연결 정상"
else
    echo "❌ 마스터 노드에 연결할 수 없습니다."
    echo "네트워크 설정을 확인하세요."
    exit 1
fi

# 마스터 노드 API 서버 확인
echo "마스터 노드 API 서버 확인 중..."
if nc -z 10.10.10.99 6443 2>/dev/null; then
    echo "✅ API 서버 접근 가능"
else
    echo "❌ API 서버에 접근할 수 없습니다."
    echo "마스터 노드에서 클러스터 초기화가 완료되었는지 확인하세요."
    exit 1
fi

# 조인 명령어 확인
echo "조인 명령어를 입력하세요."
echo "마스터 노드의 /root/worker-join-command.sh 파일 내용을 복사해서 붙여넣으세요:"
echo ""
echo "예시:"
echo "kubeadm join 10.10.10.99:6443 --token abc123.xyz789 --discovery-token-ca-cert-hash sha256:abcd1234..."
echo ""

# 사용자 입력 받기
echo "조인 명령어를 입력하고 Enter를 누르세요:"
read -r JOIN_COMMAND

# 입력 검증
if [[ $JOIN_COMMAND != kubeadm\ join\ 10.10.10.99:6443* ]]; then
    echo "❌ 잘못된 조인 명령어입니다."
    echo "올바른 형식: kubeadm join 10.10.10.99:6443 --token ... --discovery-token-ca-cert-hash ..."
    exit 1
fi

echo "입력된 조인 명령어:"
echo "$JOIN_COMMAND"
echo ""

# 확인
echo "이 명령어로 클러스터에 조인하시겠습니까? (y/N)"
read -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "조인 취소됨"
    exit 1
fi

# kubelet 서비스 상태 확인
echo "kubelet 서비스 상태 확인..."
if ! systemctl is-enabled kubelet &>/dev/null; then
    echo "❌ kubelet 서비스가 활성화되지 않았습니다."
    echo "03-install-kubernetes.sh 스크립트를 먼저 실행하세요."
    exit 1
fi

# containerd 서비스 상태 확인
echo "containerd 서비스 상태 확인..."
if ! systemctl is-active containerd &>/dev/null; then
    echo "❌ containerd 서비스가 실행되지 않았습니다."
    echo "02-install-containerd.sh 스크립트를 먼저 실행하세요."
    exit 1
fi

echo "✅ 사전 요구사항 확인 완료"

# 기존 클러스터 설정 정리 (재조인의 경우)
if [ -f "/etc/kubernetes/kubelet.conf" ]; then
    echo "기존 클러스터 설정 감지. 정리 중..."
    sudo kubeadm reset --force --cri-socket=unix:///run/containerd/containerd.sock
    sudo rm -rf /etc/kubernetes/
    sudo rm -rf /var/lib/kubelet/*
    sudo rm -rf /var/lib/etcd/
fi

# 클러스터 조인 실행
echo "클러스터 조인 실행 중..."
FULL_JOIN_COMMAND="sudo $JOIN_COMMAND --ignore-preflight-errors=Mem,FileExisting-socat,FileExisting-conntrack --cri-socket=unix:///run/containerd/containerd.sock"

echo "실행할 명령어:"
echo "$FULL_JOIN_COMMAND"
echo ""

eval $FULL_JOIN_COMMAND

# 조인 결과 확인
if [ $? -eq 0 ]; then
    echo "✅ 클러스터 조인 성공!"
else
    echo "❌ 클러스터 조인 실패"
    echo ""
    echo "문제 해결 방법:"
    echo "1. 마스터 노드에서 새로운 토큰 생성:"
    echo "   kubeadm token create --print-join-command"
    echo "2. 네트워크 연결 확인"
    echo "3. 방화벽 설정 확인"
    echo "4. 로그 확인: journalctl -u kubelet"
    exit 1
fi

# kubelet 서비스 상태 확인
echo "kubelet 서비스 상태 확인..."
sleep 5
sudo systemctl status kubelet --no-pager

# 노드 상태 확인 (마스터에서)
echo ""
echo "마스터 노드에서 노드 상태를 확인하세요:"
echo "ssh 10.10.10.99 'kubectl get nodes'"
echo ""

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        워커 노드 조인 완료                                    ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 다음 단계:"
echo "1. 마스터 노드에서 'kubectl get nodes'로 조인 확인"
echo "2. 모든 워커 노드 조인 완료 후 마스터에서 06-install-apps.sh 실행"
echo ""
echo "💡 참고:"
echo "- 노드가 Ready 상태가 되기까지 몇 분 소요될 수 있습니다"
echo "- CNI Pod가 시작되면 노드가 Ready 상태로 변경됩니다"
