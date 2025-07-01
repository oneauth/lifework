# Flannel 완전 제거 및 Calico 크린 설치 가이드

## 1단계: 현재 상태 백업 및 확인

### 클러스터 상태 백업
```bash
# 현재 상태 백업
mkdir -p ~/k8s-backup
kubectl get all -A > ~/k8s-backup/all-resources-before.yaml
kubectl get nodes -o wide > ~/k8s-backup/nodes-before.txt
ip route > ~/k8s-backup/routes-before.txt
ip addr > ~/k8s-backup/interfaces-before.txt

# etcd 백업 (중요!)
sudo ETCDCTL_API=3 etcdctl snapshot save ~/k8s-backup/etcd-backup-$(date +%Y%m%d_%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

### 현재 네트워크 상태 확인
```bash
echo "=== 현재 CNI 상태 확인 ==="
kubectl get pods -A | grep -E "(flannel|calico|weave)"
kubectl get daemonsets -A | grep -E "(flannel|calico|weave)"
kubectl get configmap -A | grep -E "(flannel|calico|weave)"

echo "=== 네트워크 인터페이스 확인 ==="
ip addr show | grep -E "(cni0|flannel|calico)"
ip route | grep -E "(cni0|flannel|calico)"

echo "=== 네트워크 포트 사용 현황 ==="
sudo netstat -tulpn | grep -E "(8472|179|4789)"
```

## 2단계: 워크로드 파드 제거 (선택사항)

### 사용자 파드 정리 (데이터 보존 필요시 백업)
```bash
# 사용자 네임스페이스의 파드 목록 확인
kubectl get pods --all-namespaces | grep -v "kube-system\|kube-public\|kube-node-lease"

# 필요시 중요한 워크로드 백업
kubectl get deployments -A -o yaml > ~/k8s-backup/deployments.yaml
kubectl get services -A -o yaml > ~/k8s-backup/services.yaml

# 사용자 파드 제거 (선택사항 - 안전을 위해)
kubectl delete pods --all --all-namespaces --grace-period=0 --force 2>/dev/null || true
```

## 3단계: Flannel 완전 제거

### Flannel Kubernetes 리소스 제거
```bash
echo "=== Flannel Kubernetes 리소스 제거 ==="

# Flannel 매니페스트로 제거 시도
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml 2>/dev/null || true

# 수동으로 Flannel 리소스 제거
kubectl delete daemonset -n kube-flannel-system kube-flannel-ds 2>/dev/null || true
kubectl delete configmap -n kube-flannel-system kube-flannel-cfg 2>/dev/null || true
kubectl delete serviceaccount -n kube-flannel-system flannel 2>/dev/null || true
kubectl delete clusterrole flannel 2>/dev/null || true
kubectl delete clusterrolebinding flannel 2>/dev/null || true
kubectl delete namespace kube-flannel-system 2>/dev/null || true

# kube-system 네임스페이스의 flannel 리소스 제거
kubectl delete daemonset -n kube-system kube-flannel-ds 2>/dev/null || true
kubectl delete configmap -n kube-system kube-flannel-cfg 2>/dev/null || true

# 잔여 파드 강제 제거
kubectl get pods -A | grep flannel | awk '{print $1 " " $2}' | xargs -n2 kubectl delete pod --force --grace-period=0 -n 2>/dev/null || true
```

### 노드별 Flannel 네트워크 인터페이스 정리
```bash
echo "=== 네트워크 인터페이스 정리 (모든 노드에서 실행) ==="

# Flannel 관련 인터페이스 제거
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete docker0 2>/dev/null || true

# CNI 브리지 인터페이스 정리
for iface in $(ip link show | grep -o 'veth[^:]*'); do
    sudo ip link delete $iface 2>/dev/null || true
done

# 네트워크 네임스페이스 정리
for ns in $(sudo ip netns list | grep -o '^[^[:space:]]*'); do
    sudo ip netns delete $ns 2>/dev/null || true
done
```

### iptables 규칙 정리
```bash
echo "=== iptables 규칙 정리 ==="

# Flannel 관련 iptables 규칙 제거
sudo iptables -t nat -F FLANNEL-POSTRTG 2>/dev/null || true
sudo iptables -t nat -X FLANNEL-POSTRTG 2>/dev/null || true
sudo iptables -F FLANNEL-FWD 2>/dev/null || true
sudo iptables -X FLANNEL-FWD 2>/dev/null || true

# CNI 관련 체인 정리
sudo iptables -t nat -F CNI-HOSTPORT-MASQ 2>/dev/null || true
sudo iptables -t nat -X CNI-HOSTPORT-MASQ 2>/dev/null || true
sudo iptables -F CNI-HOSTPORT-DNAT 2>/dev/null || true
sudo iptables -X CNI-HOSTPORT-DNAT 2>/dev/null || true

# FORWARD 체인의 CNI 관련 규칙 제거
sudo iptables -D FORWARD -i cni0 -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -o cni0 -j ACCEPT 2>/dev/null || true
```

### CNI 설정 파일 제거
```bash
echo "=== CNI 설정 파일 정리 ==="

# CNI 설정 파일 백업 후 제거
sudo mkdir -p ~/k8s-backup/cni-backup
sudo cp -r /etc/cni/net.d/* ~/k8s-backup/cni-backup/ 2>/dev/null || true
sudo rm -rf /etc/cni/net.d/*

# CNI 캐시 정리
sudo rm -rf /var/lib/cni/cache/*
sudo rm -rf /var/lib/cni/results/*

# Flannel 관련 파일 제거
sudo rm -rf /var/lib/cni/flannel/*
sudo rm -rf /run/flannel/*
```

### kubelet 재시작 및 확인
```bash
echo "=== kubelet 재시작 ==="
sudo systemctl restart kubelet
sleep 10

# 노드 상태 확인 (NotReady 상태가 정상)
kubectl get nodes
```

## 4단계: 시스템 정리 및 검증

### 완전 정리 확인
```bash
echo "=== 정리 상태 검증 ==="

# Flannel 관련 프로세스 확인
ps aux | grep flannel || echo "Flannel 프로세스 없음"

# 네트워크 인터페이스 확인
ip addr show | grep -E "(cni|flannel)" || echo "Flannel 인터페이스 정리됨"

# 포트 8472 사용 확인
sudo netstat -tulpn | grep 8472 || echo "8472 포트 해제됨"

# Kubernetes 리소스 확인
kubectl get all -A | grep flannel || echo "Flannel K8s 리소스 정리됨"

echo "=== 노드 상태 확인 ==="
kubectl get nodes -o wide
# STATUS: NotReady (정상 - CNI가 없으므로)
```

## 5단계: Calico 설치

### Calico Operator 설치
```bash
echo "=== Calico Operator 설치 ==="

# Calico Operator 다운로드 및 적용
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
kubectl create -f tigera-operator.yaml

# Operator 파드 시작 대기
echo "Calico Operator 시작 대기 중..."
kubectl wait --for=condition=Ready pod -l name=tigera-operator -n tigera-operator --timeout=120s
```

### Calico 설정 파일 생성
```bash
echo "=== Calico 설정 파일 생성 ==="

# kubeadm init에서 사용한 Pod CIDR 확인
POD_CIDR=$(kubectl cluster-info dump | grep -m 1 cluster-cidr | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*/[0-9]*' || echo "10.244.0.0/16")
echo "감지된 Pod CIDR: $POD_CIDR"

# Calico 설정 파일 생성
cat > calico-installation.yaml << EOF
# Calico Installation 설정
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Kubernetes 1.29.15와 호환되는 Calico 버전
  variant: Calico
  
  # 네트워크 설정
  calicoNetwork:
    # Pod CIDR 설정 (kubeadm init에서 사용한 값)
    ipPools:
    - blockSize: 26
      cidr: $POD_CIDR
      encapsulation: IPIP
      natOutgoing: Enabled
      nodeSelector: all()
    
    # BGP 설정 (TIBCO RV와 충돌 방지)
    bgp: Enabled
    
    # 멀티 인터페이스 환경 설정
    nodeAddressAutodetectionV4:
      firstFound: true

---
# Calico API Server 설정 (선택사항)
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

echo "Calico 설정 파일 생성 완료: calico-installation.yaml"
cat calico-installation.yaml
```

### Calico 설치 적용
```bash
echo "=== Calico 설치 적용 ==="

# Calico 설치
kubectl create -f calico-installation.yaml

echo "Calico 설치 시작됨. 설치 진행 상황 모니터링..."
```

## 6단계: Calico 설치 진행 상황 모니터링

### 설치 상태 모니터링
```bash
echo "=== Calico 설치 진행 상황 모니터링 ==="

# Installation 리소스 상태 확인
echo "1. Installation 상태 확인"
kubectl get installation default -o yaml

# 네임스페이스 생성 확인
echo "2. 네임스페이스 확인"
kubectl get namespaces | grep calico

# 파드 생성 진행 상황 (실시간 모니터링)
echo "3. Calico 파드 상태 실시간 모니터링 (2분간)"
timeout 120 watch -n 5 'kubectl get pods -n calico-system -o wide'

# 또는 수동 확인
for i in {1..24}; do
    echo "=== 체크 $i/24 ($(date)) ==="
    kubectl get pods -n calico-system -o wide
    echo "---"
    sleep 5
done
```

### DaemonSet 상태 확인
```bash
echo "=== DaemonSet 상태 확인 ==="

# calico-node DaemonSet 확인
kubectl get daemonset -n calico-system calico-node -o wide

# 각 노드별 상태 확인
kubectl describe daemonset -n calico-system calico-node

# 노드별 파드 배치 상황
kubectl get pods -n calico-system -o wide | grep calico-node
```

## 7단계: 설치 완료 검증

### 기본 상태 검증
```bash
echo "=== 기본 상태 검증 ==="

# 1. 노드 상태 확인 (Ready 상태가 되어야 함)
echo "1. 노드 상태 확인"
kubectl get nodes -o wide

# 2. Calico 파드 상태 확인
echo "2. Calico 파드 상태"
kubectl get pods -n calico-system

# 3. Calico 설치 상태 확인
echo "3. Calico Installation 상태"
kubectl get installation default -o jsonpath='{.status}' | jq '.' 2>/dev/null || kubectl get installation default -o yaml | grep -A 10 status:
```

### 네트워크 인터페이스 검증
```bash
echo "=== 네트워크 인터페이스 검증 ==="

# 1. Calico 인터페이스 생성 확인
echo "1. 네트워크 인터페이스 확인"
ip addr show | grep -E "(cali|tunl)"

# 2. 라우팅 테이블 확인
echo "2. 라우팅 테이블"
ip route | grep -E "(cali|tunl|bird)"

# 3. BGP 피어 상태 확인 (calicoctl 없이)
echo "3. Calico 노드 상태 확인"
kubectl get nodes -o yaml | grep -A 5 "node.alpha.kubernetes.io/ttl"
```

### CoreDNS 상태 확인
```bash
echo "=== CoreDNS 상태 확인 ==="

# CoreDNS 파드 상태
kubectl get pods -n kube-system | grep coredns

# CoreDNS 로그 확인
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=10
```

## 8단계: 기능 테스트

### 네트워크 연결성 테스트
```bash
echo "=== 네트워크 연결성 테스트 ==="

# 1. 테스트 파드 생성
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-1
  labels:
    app: test
spec:
  containers:
  - name: test
    image: busybox:1.35
    command: ['sleep', '3600']
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-2
  labels:
    app: test
spec:
  containers:
  - name: test
    image: busybox:1.35
    command: ['sleep', '3600']
EOF

# 파드 시작 대기
echo "테스트 파드 시작 대기..."
kubectl wait --for=condition=Ready pod test-pod-1 --timeout=60s
kubectl wait --for=condition=Ready pod test-pod-2 --timeout=60s

# 2. 파드 IP 확인
echo "2. 테스트 파드 IP 확인"
kubectl get pods -o wide | grep test-pod
```

### DNS 및 서비스 테스트
```bash
echo "=== DNS 및 서비스 테스트 ==="

# 1. DNS 해상도 테스트
echo "1. DNS 테스트"
kubectl exec test-pod-1 -- nslookup kubernetes.default.svc.cluster.local

# 2. 파드 간 통신 테스트
echo "2. 파드 간 통신 테스트"
POD2_IP=$(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}')
kubectl exec test-pod-1 -- ping -c 3 $POD2_IP

# 3. 서비스 테스트
echo "3. 서비스 생성 및 테스트"
kubectl expose pod test-pod-2 --port=80 --target-port=8080 --name=test-service
kubectl exec test-pod-1 -- nslookup test-service.default.svc.cluster.local
```

### 인터넷 연결 테스트
```bash
echo "=== 인터넷 연결 테스트 ==="

# 외부 DNS 및 인터넷 연결 확인
kubectl exec test-pod-1 -- nslookup google.com
kubectl exec test-pod-1 -- wget -qO- --timeout=10 http://httpbin.org/ip
```

## 9단계: 포트 충돌 검증

### TIBCO RV와 포트 충돌 확인
```bash
echo "=== 포트 충돌 검증 ==="

# 1. 8472 포트 사용 현황 (TIBCO RV 확인)
echo "1. UDP 8472 포트 상태"
sudo netstat -tulpn | grep 8472

# 2. BGP 포트 (179) 사용 확인
echo "2. TCP 179 포트 상태 (BGP)"
sudo netstat -tulpn | grep 179

# 3. Calico가 사용하는 포트 확인
echo "3. Calico 프로세스 포트 사용"
sudo netstat -tulpn | grep calico

# 4. IPIP 터널 확인 (포트 사용 안함)
echo "4. IPIP 터널 인터페이스"
ip addr show tunl0 2>/dev/null || echo "IPIP 터널 인터페이스 없음 (정상 - 필요시에만 생성)"
```

## 10단계: 성능 및 안정성 확인

### 리소스 사용량 확인
```bash
echo "=== 리소스 사용량 확인 ==="

# 1. 노드 리소스 사용량
kubectl top nodes 2>/dev/null || echo "metrics-server가 필요합니다"

# 2. Calico 파드 리소스 사용량
kubectl top pods -n calico-system 2>/dev/null || echo "metrics-server가 필요합니다"

# 3. 시스템 리소스 사용량
echo "CPU 및 메모리 사용량:"
top -bn1 | head -10
```

### 로그 확인
```bash
echo "=== 로그 확인 ==="

# 1. Calico 노드 로그
echo "1. Calico 노드 로그 (최근 20줄)"
kubectl logs -n calico-system -l k8s-app=calico-node --tail=20

# 2. Calico 컨트롤러 로그
echo "2. Calico 컨트롤러 로그"
kubectl logs -n calico-system -l k8s-app=calico-kube-controllers --tail=20

# 3. kubelet 로그
echo "3. kubelet 로그 (최근 10줄)"
sudo journalctl -u kubelet --no-pager --lines=10
```

## 11단계: 정리 및 문서화

### 테스트 리소스 정리
```bash
echo "=== 테스트 리소스 정리 ==="

# 테스트 파드 및 서비스 제거
kubectl delete pod test-pod-1 test-pod-2
kubectl delete service test-service

# 임시 파일 정리
rm -f tigera-operator.yaml calico-installation.yaml
```

### 설치 후 상태 백업
```bash
echo "=== 설치 완료 상태 백업 ==="

# 설치 후 상태 백업
kubectl get all -A > ~/k8s-backup/all-resources-after.yaml
kubectl get nodes -o wide > ~/k8s-backup/nodes-after.txt
ip route > ~/k8s-backup/routes-after.txt
ip addr > ~/k8s-backup/interfaces-after.txt

# Calico 설정 백업
kubectl get installation default -o yaml > ~/k8s-backup/calico-installation.yaml
kubectl get pods -n calico-system -o yaml > ~/k8s-backup/calico-pods.yaml

echo "백업 파일 위치: ~/k8s-backup/"
ls -la ~/k8s-backup/
```

## 최종 검증 체크리스트

### ✅ 성공 기준
```bash
echo "=== 최종 검증 체크리스트 ==="

# 1. 노드 Ready 상태
echo "✅ 노드 상태 확인"
kubectl get nodes | grep Ready && echo "✅ 노드 Ready 상태" || echo "❌ 노드 NotReady"

# 2. Calico 파드 Running 상태
echo "✅ Calico 파드 상태 확인"
kubectl get pods -n calico-system | grep -v Running || echo "✅ 모든 Calico 파드 Running"

# 3. CoreDNS 정상 작동
echo "✅ CoreDNS 상태 확인"
kubectl get pods -n kube-system | grep coredns | grep Running && echo "✅ CoreDNS 정상" || echo "❌ CoreDNS 문제"

# 4. 네트워크 연결성
echo "✅ 네트워크 연결성 확인"
kubectl run temp-test --image=busybox:1.35 --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local && echo "✅ DNS 정상" || echo "❌ DNS 문제"

# 5. 포트 충돌 없음
echo "✅ 포트 충돌 확인"
sudo netstat -tulpn | grep 8472 | grep -v calico && echo "⚠️ 8472 포트 사용됨 (TIBCO RV)" || echo "✅ 8472 포트 Calico 미사용"

echo ""
echo "🎉 Calico 설치 완료!"
echo "📊 현재 상태:"
kubectl get nodes
kubectl get pods -n calico-system
```

## 문제 해결 가이드

### 일반적인 문제와 해결책

**1. 노드가 계속 NotReady 상태**
```bash
# Calico 파드 로그 확인
kubectl logs -n calico-system -l k8s-app=calico-node

# kubelet 재시작
sudo systemctl restart kubelet
```

**2. DNS가 작동하지 않음**
```bash
# CoreDNS 재시작
kubectl rollout restart deployment/coredns -n kube-system

# CoreDNS 설정 확인
kubectl get configmap coredns -n kube-system -o yaml
```

**3. 파드 간 통신 불가**
```bash
# iptables 규칙 확인
sudo iptables -L -n | grep FORWARD

# Calico 정책 확인
kubectl get networkpolicy -A
```

이제 Flannel이 완전히 제거되고 Calico가 깔끔하게 설치되었습니다!