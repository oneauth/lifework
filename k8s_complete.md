### 9.1 클러스터 관련 문제

#### 노드가 NotReady 상태
```bash
# 노드 상태 상세 확인
kubectl describe node <node-name>

# kubelet 로그 확인
ssh <node-ip> "sudo journalctl -u kubelet -f"

# CNI 문제 확인
kubectl get pods -n kube-flannel
```

#### Pod가 Pending 상태
```bash
# Pod 이벤트 확인
kubectl describe pod <pod-name> -n <namespace>

# 노드 리소스 확인
kubectl top nodes
kubectl describe nodes

# 스케줄링 문제 확인
kubectl get events --sort-by=.metadata.creationTimestamp
```

#### 워커 노드 조인 실패
```bash
# 마스터 노드에서 새 토큰 생성
kubeadm token create --print-join-command

# 워커 노드에서 이전 조인 시도 정리
sudo kubeadm reset
sudo systemctl restart kubelet containerd

# 새 토큰으로 재시도
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash> --ignore-preflight-errors=Mem
```

### 9.2 애플리케이션 관련 문제

#### Harbor 설치 실패
```bash
# Harbor Pod 상태 확인
kubectl get pods -n harbor
kubectl describe pod <harbor-pod> -n harbor

# Harbor 서비스 확인
kubectl get svc -n harbor

# 저장소 문제 확인
kubectl get pv,pvc -n harbor
```

#### Kafka 클러스터 형성 실패
```bash
# Kafka 및 Zookeeper Pod 로그 확인
kubectl logs <kafka-pod> -n kafka
kubectl logs <zookeeper-pod> -n kafka

# Kafka 토픽 테스트
kubectl exec -it <kafka-pod> -n kafka -- kafka-topics.sh --bootstrap-server localhost:9092 --list
```

### 9.3 네트워크 관련 문제

#### Pod 간 통신 실패
```bash
# 네트워크 정책 확인
kubectl get networkpolicies --all-namespaces

# CNI 설정 확인
kubectl get pods -n kube-flannel -o wide

# 노드 간 통신 테스트
ping 10.10.10.100  # 각 노드에서 다른 노드로
```

#### 외부 접속 실패
```bash
# NodePort 서비스 확인
kubectl get svc --all-namespaces | grep NodePort

# 방화벽 상태 확인 (모든 노드에서)
sudo firewall-cmd --list-ports

# 포트 리스닝 확인
sudo ss -tlnp | grep <port>
```

### 9.4 로그 수집 스크립트

```bash
# 종합 로그 수집 스크립트
cat <<'EOF' > collect-cluster-logs.sh
#!/bin/bash

LOGDIR="/tmp/k8s-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p $LOGDIR

echo "클러스터 로그 수집 중... 저장 위치: $LOGDIR"

# 클러스터 기본 정보
kubectl cluster-info > $LOGDIR/cluster-info.txt
kubectl get nodes -o wide > $LOGDIR/nodes.txt
kubectl get pods --all-namespaces -o wide > $LOGDIR/all-pods.txt
kubectl get svc --all-namespaces > $LOGDIR/all-services.txt
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp > $LOGDIR/events.txt

# 시스템 Pod 로그
echo "시스템 Pod 로그 수집 중..."
kubectl logs -n kube-system --selector=component=kube-apiserver > $LOGDIR/kube-apiserver.log 2>&1
kubectl logs -n kube-system --selector=component=kube-controller-manager > $LOGDIR/kube-controller-manager.log 2>&1
kubectl logs -n kube-system --selector=component=kube-scheduler > $LOGDIR/kube-scheduler.log 2>&1

# 애플리케이션 로그
for ns in harbor cattle-system awx kafka; do
    echo "$ns 네임스페이스 로그 수집 중..."
    kubectl get pods -n $ns > $LOGDIR/${ns}-pods.txt
    
    kubectl get pods -n $ns --no-headers | awk '{print $1}' | while read pod; do
        kubectl logs $pod -n $ns > $LOGDIR/${ns}-${pod}.log 2>&1
    done
done

# 노드별 시스템 로그 (SSH 접근 가능한 경우)
for node in 10.10.10.99 10.10.10.100 10.10.10.103 10.10.10.105; do
    echo "$node 노드 로그 수집 중..."
    ssh -o ConnectTimeout=5 chris@$node "sudo journalctl -u kubelet --since '1 hour ago'" > $LOGDIR/kubelet-$node.log 2>/dev/null
    ssh -o ConnectTimeout=5 chris@$node "sudo journalctl -u containerd --since '1 hour ago'" > $LOGDIR/containerd-$node.log 2>/dev/null
done

echo "로그 수집 완료: $LOGDIR"
ls -la $LOGDIR/

# 로그 압축
tar -czf $LOGDIR.tar.gz -C /tmp $(basename $LOGDIR)
echo "압축 파일: $LOGDIR.tar.gz"
EOF

chmod +x collect-cluster-logs.sh
```

---

## 10. 백업 및 복구

### 10.1 etcd 백업

```bash
# etcd 백업 스크립트
cat <<'EOF' > backup-etcd.sh
#!/bin/bash

BACKUP_DIR="/backup/etcd/$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR

echo "etcd 백업 시작..."

# etcd 스냅샷 생성
sudo ETCDCTL_API=3 etcdctl snapshot save $BACKUP_DIR/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 백업 검증
sudo ETCDCTL_API=3 etcdctl snapshot status $BACKUP_DIR/etcd-snapshot.db

# 설정 파일 백업
sudo cp -r /etc/kubernetes $BACKUP_DIR/
sudo cp -r /var/lib/kubelet $BACKUP_DIR/

echo "etcd 백업 완료: $BACKUP_DIR"
EOF

chmod +x backup-etcd.sh
```

### 10.2 클러스터 전체 백업

```bash
# 클러스터 전체 백업 스크립트
cat <<'EOF' > backup-cluster.sh
#!/bin/bash

BACKUP_DIR="/backup/k8s-cluster/$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR

echo "클러스터 전체 백업 시작..."

# 1. etcd 백업
./backup-etcd.sh

# 2. 모든 리소스 백업
kubectl get all --all-namespaces -o yaml > $BACKUP_DIR/all-resources.yaml

# 3. 네임스페이스별 상세 백업
for ns in default kube-system kube-flannel harbor cattle-system awx kafka; do
    echo "백업 중: $ns 네임스페이스"
    mkdir -p $BACKUP_DIR/namespaces/$ns
    
    # 모든 리소스 백업
    kubectl get all -n $ns -o yaml > $BACKUP_DIR/namespaces/$ns/all-resources.yaml
    
    # ConfigMap 백업
    kubectl get configmaps -n $ns -o yaml > $BACKUP_DIR/namespaces/$ns/configmaps.yaml
    
    # Secret 백업
    kubectl get secrets -n $ns -o yaml > $BACKUP_DIR/namespaces/$ns/secrets.yaml
    
    # PVC 백업
    kubectl get pvc -n $ns -o yaml > $BACKUP_DIR/namespaces/$ns/pvc.yaml 2>/dev/null
done

# 4. 클러스터 수준 리소스 백업
echo "클러스터 리소스 백업 중..."
kubectl get nodes -o yaml > $BACKUP_DIR/nodes.yaml
kubectl get pv -o yaml > $BACKUP_DIR/persistent-volumes.yaml
kubectl get storageclass -o yaml > $BACKUP_DIR/storage-classes.yaml
kubectl get clusterroles -o yaml > $BACKUP_DIR/cluster-roles.yaml
kubectl get clusterrolebindings -o yaml > $BACKUP_DIR/cluster-role-bindings.yaml

# 5. Helm 릴리즈 백업
echo "Helm 릴리즈 백업 중..."
helm list --all-namespaces > $BACKUP_DIR/helm-releases.txt

# 각 릴리즈의 values 백업
helm list --all-namespaces --output json | jq -r '.[] | "\(.name) \(.namespace)"' | while read name namespace; do
    mkdir -p $BACKUP_DIR/helm-values/$namespace
    helm get values $name -n $namespace > $BACKUP_DIR/helm-values/$namespace/$name-values.yaml 2>/dev/null
done

# 6. 사용자 정의 리소스 백업 (CRD)
echo "CRD 백업 중..."
kubectl get crd -o yaml > $BACKUP_DIR/custom-resource-definitions.yaml

# 7. 백업 정보 파일 생성
cat <<EOL > $BACKUP_DIR/backup-info.txt
클러스터 백업 정보
==================
백업 시간: $(date)
클러스터: $(kubectl config current-context)
Kubernetes 버전: $(kubectl version --short)
노드 수: $(kubectl get nodes --no-headers | wc -l)
네임스페이스 수: $(kubectl get namespaces --no-headers | wc -l)
EOL

# 8. 백업 압축
echo "백업 압축 중..."
tar -czf $BACKUP_DIR.tar.gz -C /backup/k8s-cluster $(basename $BACKUP_DIR)

echo "클러스터 백업 완료: $BACKUP_DIR.tar.gz"
ls -lh $BACKUP_DIR.tar.gz
EOF

chmod +x backup-cluster.sh
```

### 10.3 KVM 스냅샷 생성

```bash
# 호스트에서 전체 클러스터 스냅샷 생성 스크립트
cat <<'EOF' > create-cluster-snapshots.sh
#!/bin/bash

# 모든 VM 스냅샷 생성 (호스트에서 실행)
VMS=("dover-rhel94-master" "dover-rhel94-worker1" "dover-rhel94-worker2" "dover-rhel94-worker3")
SNAPSHOT_NAME="k8s-cluster-installed-$(date +%Y%m%d_%H%M%S)"

echo "클러스터 VM 스냅샷 생성 중..."

for vm in "${VMS[@]}"; do
    echo "스냅샷 생성: $vm"
    sudo virsh snapshot-create-as $vm $SNAPSHOT_NAME "Kubernetes 클러스터 설치 완료"
    
    if [ $? -eq 0 ]; then
        echo "✅ $vm 스냅샷 생성 완료"
    else
        echo "❌ $vm 스냅샷 생성 실패"
    fi
done

echo "모든 VM 스냅샷 생성 완료: $SNAPSHOT_NAME"

# 스냅샷 목록 확인
for vm in "${VMS[@]}"; do
    echo "[$vm 스냅샷 목록]"
    sudo virsh snapshot-list $vm
    echo ""
done
EOF

chmod +x create-cluster-snapshots.sh
```

---

## 11. 모니터링 및 관리

### 11.1 metrics-server 설치

```bash
# metrics-server 설치 (리소스 모니터링용)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# TLS 검증 비활성화 (테스트 환경용)
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# 설치 확인
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
kubectl top pods --all-namespaces
```

### 11.2 클러스터 모니터링 대시보드

```bash
# 실시간 클러스터 모니터링 스크립트
cat <<'EOF' > monitor-cluster.sh
#!/bin/bash

watch -n 30 '
clear
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Kubernetes 클러스터 실시간 모니터링                        ║"
echo "║                         $(date +"%Y-%m-%d %H:%M:%S")                           ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

echo ""
echo "🏢 노드 상태 및 리소스:"
kubectl top nodes 2>/dev/null || echo "metrics-server 대기 중..."

echo ""
echo "📊 네임스페이스별 Pod 수:"
kubectl get pods --all-namespaces --no-headers | awk "{print \$1}" | sort | uniq -c | head -10

echo ""
echo "⚠️  문제가 있는 Pod:"
kubectl get pods --all-namespaces --no-headers | grep -v Running | grep -v Completed | head -5

echo ""
echo "🔄 최근 이벤트:"
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | tail -5

echo ""
echo "💾 저장소 사용량:"
kubectl get pvc --all-namespaces --no-headers | wc -l | xargs echo "PVC 총 개수:"

echo ""
echo "다음 업데이트: 30초 후 (Ctrl+C로 종료)"
'
EOF

chmod +x monitor-cluster.sh
```

### 11.3 자동 헬스체크

```bash
# 자동 헬스체크 및 알림 스크립트
cat <<'EOF' > auto-healthcheck.sh
#!/bin/bash

HEALTHCHECK_LOG="/var/log/k8s-healthcheck.log"
EMAIL_ALERT="admin@company.com"  # 실제 이메일로 변경

perform_healthcheck() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local issues=0
    
    echo "[$timestamp] 헬스체크 시작" >> $HEALTHCHECK_LOG
    
    # 노드 상태 확인
    local not_ready_nodes=$(kubectl get nodes --no-headers | grep -v Ready | wc -l)
    if [ $not_ready_nodes -gt 0 ]; then
        echo "[$timestamp] 경고: $not_ready_nodes 개 노드가 Ready 상태가 아님" >> $HEALTHCHECK_LOG
        issues=$((issues + 1))
    fi
    
    # 시스템 Pod 확인
    local failed_system_pods=$(kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed | wc -l)
    if [ $failed_system_pods -gt 0 ]; then
        echo "[$timestamp] 경고: $failed_system_pods 개 시스템 Pod에 문제 발생" >> $HEALTHCHECK_LOG
        issues=$((issues + 1))
    fi
    
    # 애플리케이션 Pod 확인
    for ns in harbor cattle-system awx kafka; do
        local failed_pods=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l)
        if [ $failed_pods -gt 0 ]; then
            echo "[$timestamp] 경고: $ns 네임스페이스에서 $failed_pods 개 Pod에 문제 발생" >> $HEALTHCHECK_LOG
            issues=$((issues + 1))
        fi
    done
    
    # 디스크 사용량 확인 (80% 이상 경고)
    local disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ $disk_usage -gt 80 ]; then
        echo "[$timestamp] 경고: 디스크 사용량 ${disk_usage}%" >> $HEALTHCHECK_LOG
        issues=$((issues + 1))
    fi
    
    if [ $issues -eq 0 ]; then
        echo "[$timestamp] 모든 상태 정상" >> $HEALTHCHECK_LOG
    else
        echo "[$timestamp] 총 $issues 개 이슈 발견" >> $HEALTHCHECK_LOG
        
        # 이메일 알림 (mailx가 설치된 경우)
        if command -v mailx &> /dev/null; then
            echo "Kubernetes 클러스터에서 $issues 개 이슈가 발견되었습니다. 로그를 확인하세요: $HEALTHCHECK_LOG" | \
            mailx -s "K8s 클러스터 이슈 알림" $EMAIL_ALERT
        fi
    fi
    
    return $issues
}

# 메인 루프
if [ "$1" = "--daemon" ]; then
    echo "자동 헬스체크 데몬 시작..."
    while true; do
        perform_healthcheck
        sleep 300  # 5분마다 체크
    done
else
    echo "일회성 헬스체크 실행..."
    perform_healthcheck
    echo "상세 로그: $HEALTHCHECK_LOG"
fi
EOF

chmod +x auto-healthcheck.sh

# 크론탭에 등록 (선택사항)
# echo "*/10 * * * * /path/to/auto-healthcheck.sh" | crontab -
```

---

## 12. 운영 가이드

### 12.1 일상 운영 체크리스트

```bash
# 일일 운영 체크 스크립트
cat <<'EOF' > daily-operations-checklist.sh
#!/bin/bash

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        일일 운영 체크리스트                                   ║"
echo "║                         $(date +"%Y년 %m월 %d일")                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

check_item() {
    local item="$1"
    local command="$2"
    local expected="$3"
    
    printf "%-50s: " "$item"
    
    local result=$(eval $command 2>/dev/null)
    if [ "$result" = "$expected" ] || [[ "$result" =~ $expected ]]; then
        echo "✅ 정상"
        return 0
    else
        echo "❌ 이상 ($result)"
        return 1
    fi
}

echo ""
echo "🔍 기본 상태 확인:"

# 1. 클러스터 연결성
check_item "kubectl 연결" "kubectl cluster-info --short | grep -c 'is running'" "1"

# 2. 노드 상태
check_item "모든 노드 Ready" "kubectl get nodes --no-headers | grep -c Ready" "4"

# 3. 시스템 Pod 상태
check_item "kube-system Pod 정상" "kubectl get pods -n kube-system --no-headers | grep -c Running" "[0-9]+"

# 4. CNI 상태
check_item "Flannel Pod 정상" "kubectl get pods -n kube-flannel --no-headers | grep -c Running" "[0-9]+"

echo ""
echo "🚀 애플리케이션 상태 확인:"

# 애플리케이션별 상태 확인
apps=("harbor" "cattle-system" "awx" "kafka")
for app in "${apps[@]}"; do
    total=$(kubectl get pods -n $app --no-headers 2>/dev/null | wc -l)
    running=$(kubectl get pods -n $app --no-headers 2>/dev/null | grep Running | wc -l)
    
    printf "%-50s: " "$app 애플리케이션"
    if [ $total -gt 0 ]; then
        if [ $running -eq $total ]; then
            echo "✅ 정상 ($running/$total)"
        else
            echo "⚠️  확인 필요 ($running/$total)"
        fi
    else
        echo "❌ 설치되지 않음"
    fi
done

echo ""
echo "💾 리소스 사용량 확인:"

# 디스크 사용량
printf "%-50s: " "디스크 사용량"
disk_usage=$(df / | awk 'NR==2 {print $5}')
disk_num=$(echo $disk_usage | sed 's/%//')
if [ $disk_num -lt 80 ]; then
    echo "✅ 정상 ($disk_usage)"
else
    echo "⚠️  높음 ($disk_usage)"
fi

# 메모리 사용량 (가능한 경우)
if command -v free &> /dev/null; then
    printf "%-50s: " "메모리 사용량"
    mem_usage=$(free | awk 'NR==2{printf "%.0f%%", $3*100/$2}')
    echo "📊 $mem_usage"
fi

echo ""
echo "🔧 권장 조치사항:"

# 문제가 있는 Pod 확인
problem_pods=$(kubectl get pods --all-namespaces --no-headers | grep -v Running | grep -v Completed)
if [ ! -z "$problem_pods" ]; then
    echo "  ⚠️  문제가 있는 Pod 확인 및 재시작 검토:"
    echo "$problem_pods" | while read line; do
        echo "    - $line"
    done
else
    echo "  ✅ 모든 Pod가 정상 상태입니다."
fi

echo ""
echo "📅 다음 확인 사항:"
echo "  - [ ] 백업 상태 확인"
echo "  - [ ] 보안 패치 확인"
echo "  - [ ] 용량 계획 검토"
echo "  - [ ] 로그 정리"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                            체크리스트 완료                                    ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
EOF

chmod +x daily-operations-checklist.sh
```

### 12.2 유지보수 스크립트

```bash
# 클러스터 유지보수 스크립트
cat <<'EOF' > maintenance-cluster.sh
#!/bin/bash

echo "Kubernetes 클러스터 유지보수 시작..."

# 1. 불필요한 이미지 정리 (모든 노드에서)
echo "1. 사용하지 않는 컨테이너 이미지 정리..."
for node in 10.10.10.99 10.10.10.100 10.10.10.103 10.10.10.105; do
    echo "  정리 중: $node"
    ssh chris@$node "sudo crictl rmi --prune" 2>/dev/null || echo "    $node 접속 실패"
done

# 2. 완료된 Pod 정리
echo "2. 완료된 Pod 정리..."
kubectl delete pods --all-namespaces --field-selector=status.phase=Succeeded
kubectl delete pods --all-namespaces --field-selector=status.phase=Failed

# 3. 오래된 ReplicaSet 정리
echo "3. 오래된 ReplicaSet 정리..."
kubectl get rs --all-namespaces --no-headers | awk '$3 == 0 {print $1, $2}' | while read ns rs; do
    kubectl delete rs $rs -n $ns
done

# 4. 로그 로테이션 (필요시)
echo "4. 로그 정리..."
find /var/log -name "*.log" -size +100M -exec truncate -s 50M {} \; 2>/dev/null

# 5. etcd 압축
echo "5. etcd 압축..."
kubectl exec -n kube-system etcd-dover-rhel94-master -- etcdctl --endpoints=localhost:2379 \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  compact $(kubectl exec -n kube-system etcd-dover-rhel94-master -- etcdctl --endpoints=localhost:2379 \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  endpoint status --write-out="json" | jq -r '.[0].Status.header.revision')

echo "클러스터 유지보수 완료!"
EOF

chmod +x maintenance-cluster.sh
```

---

## 13. 최종 확인 및 완료

### 13.1 설치 완료 확인서

```bash
# 최종 설치 완료 확인서 생성
cat <<'EOF' > generate-completion-report.sh
#!/bin/bash

REPORT_FILE="k8s-installation-completion-report-$(date +%Y%m%d_%H%M%S).txt"

cat <<EOL > $REPORT_FILE
╔══════════════════════════════════════════════════════════════════════════════╗
║                    Kubernetes 클러스터 설치 완료 보고서                       ║
║                              $(date +"%Y년 %m월 %d일")                         ║
╚══════════════════════════════════════════════════════════════════════════════╝

1. 클러스터 구성 정보
====================
클러스터 이름: k8s-cluster
Kubernetes 버전: $(kubectl version --short --client | grep Client)
노드 구성:
$(kubectl get nodes -o custom-columns="이름:.metadata.name,IP:.status.addresses[0].address,역할:.metadata.labels.node-role\.kubernetes\.io/control-plane,상태:.status.conditions[-1].type" --no-headers | sed 's/^/  /')

2. 설치된 애플리케이션
=====================
$(kubectl get pods --all-namespaces --no-headers | awk '{print $1}' | sort | uniq -c | sed 's/^/  /')

3. 외부 접속 서비스
==================
$(kubectl get svc --all-namespaces | grep NodePort | awk '{print "  " $1 "/" $2 ": http://10.10.10.99:" $5}' | sed 's/:.*//' | sed 's/$//')

4. 저장소 현황
=============
PersistentVolume: $(kubectl get pv --no-headers 2>/dev/null | wc -l)개
PersistentVolumeClaim: $(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)개

5. 주요 계정 정보
================
Harbor: admin / Harbor12345
Rancher: admin / $(kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null || echo "확인 필요")
AWX: admin / $(kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx 2>/dev/null | base64 --decode || echo "확인 필요")

6. 설치 검증 결과
================
노드 상태: $(kubectl get nodes --no-headers | grep Ready | wc -l)/$(kubectl get nodes --no-headers | wc -l) Ready
시스템 Pod: $(kubectl get pods -n kube-system --no-headers | grep Running | wc -l)/$(kubectl get pods -n kube-system --no-headers | wc -l) Running
전체 Pod: $(kubectl get pods --all-namespaces --no-headers | grep Running | wc -l)/$(kubectl get pods --all-namespaces --no-headers | wc -l) Running

7. 운영 가이드
=============
- 일일 점검: ./daily-operations-checklist.sh
- 헬스체크: ./check-pod-health.sh
- 모니터링: ./monitor-cluster.sh
- 백업: ./backup-cluster.sh
- 유지보수: ./maintenance-cluster.sh

8. 문제 해결
===========
- 로그 수집: ./collect-cluster-logs.sh
- 종합 검증: ./final-verification-dashboard.sh

설치 완료 시간: $(date)
설치자: $(whoami)
호스트: $(hostname)

╔══════════════════════════════════════════════════════════════════════════════╗
║                              설치 완료                                        ║
║        🎉 Kubernetes 클러스터가 성공적으로 구축되었습니다! 🎉                ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOL

echo "설치 완료 보고서 생성: $REPORT_FILE"
cat $REPORT_FILE
EOF

chmod +x generate-completion-report.sh
./generate-completion-report.sh
```

---

## 부록: 빠른 참조

### 주요 명령어 모음

```bash
# 클러스터 상태 확인
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods --all-namespaces

# 리소스 모니터링
kubectl top nodes
kubectl top pods --all-namespaces

# 문제 해결
kubectl describe node <node-name>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl get events --sort-by=.metadata.creationTimestamp

# 서비스 관리
systemctl status kubelet containerd
journalctl -u kubelet -f
journalctl -u containerd -f
```

### 네트워크 정보

| 구성 요소 | IP 주소 | 포트 | 접속 URL |
|----------|---------|------|----------|
| Master Node | 10.10.10.99 | 6443 | kubectl API |
| Harbor | 10.10.10.99 | 30002 | http://10.10.10.99:30002 |
| Rancher | 10.10.10.99 | 30080 | http://10.10.10.99:30080 |
| AWX | 10.10.10.99 | 30081 | http://10.10.10.99:30081 |
| Kafka | 10.10.10.99 | 30090-30092 | 외부 접속용 |

### 파일 위치

- kubectl 설정: `~/.kube/config`
- kubelet 설정: `/var/lib/kubelet/config.yaml`
- containerd 설정: `/etc/containerd/config.toml`
- 로그 위치: `/var/log/containers/`, `journalctl -u kubelet`

---

이 가이드를 따라하면 RHEL 9.4 폐쇄망 환경에서 4노드 Kubernetes 클러스터와 모든 필요한 애플리케이션들을 성공적으로 설치하고 운영할 수 있습니다.### 7.2 Rancher UI 설치

```bash
# Rancher 네임스페이스 생성
kubectl create namespace cattle-system

# Rancher Helm 저장소 추가
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

# Rancher values 파일 생성
cat <<EOF > rancher-values.yaml
hostname: rancher.k8s.local
replicas: 1
bootstrapPassword: admin

# 마스터 노드에만 스케줄링
nodeSelector:
  node-role.kubernetes.io/control-plane: ""
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule

# 리소스 제한
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# 서비스 타입 설정
service:
  type: NodePort
  ports:
    http: 30080
    https: 30443
EOF

# Rancher 설치
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  -f rancher-values.yaml

# 설치 확인
kubectl get pods -n cattle-system -w

# 초기 비밀번호 확인
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}'
```

### 7.3 AWX 설치

```bash
# AWX 네임스페이스 생성
kubectl create namespace awx

# AWX Operator 설치
kubectl apply -f https://raw.githubusercontent.com/ansible/awx-operator/devel/deploy/awx-operator.yaml -n awx

# AWX 인스턴스 생성 (워커 노드에 분산 배치)
cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  service_type: nodeport
  nodeport_port: 30081
  replicas: 2
  
  # 워커 노드에만 스케줄링
  node_selector: |
    kubernetes.io/os: linux
  
  # 리소스 제한
  web_resource_requirements:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
      
  task_resource_requirements:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
      
  postgres_resource_requirements:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 300m
      memory: 512Mi
EOF

# 설치 확인
kubectl get pods -n awx -w

# 관리자 비밀번호 확인 (설치 완료 후)
kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx | base64 --decode
```

### 7.4 Apache Kafka 설치

```bash
# Kafka 네임스페이스 생성
kubectl create namespace kafka

# Strimzi Operator 설치
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka

# Kafka 클러스터 생성 (워커 노드 분산 배치)
cat# RHEL 9.4 폐쇄망 환경 Kubernetes 완전 설치 가이드

## 개요

KVM 테스트 환경의 RHEL 9.4에서 폐쇄망 조건으로 다음 구성 요소를 설치하는 완전한 가이드입니다.

### 설치 대상
- **Kubernetes 1.29** (containerd + podman, Docker 없음)
- **Rancher UI** - Kubernetes 관리 웹 인터페이스
- **AWX** - Ansible Tower 오픈소스 버전  
- **Apache Kafka** - 메시지 브로커
- **Harbor** - 컨테이너 레지스트리

### 클러스터 구성
- **Master Node**: 10.10.10.99 (dover-rhel94-master)
- **Worker Node 1**: 10.10.10.100 (dover-rhel94-worker1)
- **Worker Node 2**: 10.10.10.103 (dover-rhel94-worker2)
- **Worker Node 3**: 10.10.10.105 (dover-rhel94-worker3)

### 환경 정보
- **OS**: RHEL 9.4 (KVM 가상머신)
- **메모리**: 2GB+ (권장), 1271MB (최소 테스트용)
- **네트워크**: 폐쇄망 환경 (10.10.10.0/24)
- **바이너리**: `/usr/local/bin`에 수동 설치

---

## 0. 클러스터 환경 준비

### 0.1 모든 노드 공통 설정

**모든 노드 (Master + Worker)에서 수행해야 하는 작업입니다.**

#### 호스트명 및 네트워크 설정

```bash
# 각 노드에서 호스트명 설정
# Master 노드에서:
sudo hostnamectl set-hostname dover-rhel94-master

# Worker 노드들에서:
# sudo hostnamectl set-hostname dover-rhel94-worker1  # 10.10.10.100
# sudo hostnamectl set-hostname dover-rhel94-worker2  # 10.10.10.103  
# sudo hostnamectl set-hostname dover-rhel94-worker3  # 10.10.10.105

# 모든 노드의 /etc/hosts 파일 설정
sudo tee -a /etc/hosts <<EOF
10.10.10.99  dover-rhel94-master k8s-master
10.10.10.100 dover-rhel94-worker1 k8s-worker1
10.10.10.103 dover-rhel94-worker2 k8s-worker2
10.10.10.105 dover-rhel94-worker3 k8s-worker3
EOF
```

#### SSH 키 배포 (선택사항)

```bash
# Master 노드에서 SSH 키 생성
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# 모든 워커 노드에 SSH 키 배포
for ip in 10.10.10.100 10.10.10.103 10.10.10.105; do
    ssh-copy-id chris@$ip
done
```

### 0.2 클러스터 검증 스크립트

```bash
# 클러스터 연결성 확인 스크립트 (Master 노드에서 실행)
cat <<'EOF' > verify-cluster-connectivity.sh
#!/bin/bash

NODES=("10.10.10.99:master" "10.10.10.100:worker1" "10.10.10.103:worker2" "10.10.10.105:worker3")

echo "=== 클러스터 노드 연결성 확인 ==="

for node in "${NODES[@]}"; do
    IP=$(echo $node | cut -d: -f1)
    NAME=$(echo $node | cut -d: -f2)
    
    echo -n "  $NAME ($IP): "
    if ping -c 1 -W 2 $IP &>/dev/null; then
        echo "✅ 연결됨"
    else
        echo "❌ 연결 실패"
    fi
done

echo -e "\n=== DNS 해결 확인 ==="
for hostname in dover-rhel94-master dover-rhel94-worker1 dover-rhel94-worker2 dover-rhel94-worker3; do
    echo -n "  $hostname: "
    if nslookup $hostname &>/dev/null || getent hosts $hostname &>/dev/null; then
        echo "✅ 해결됨"
    else
        echo "❌ 해결 실패"
    fi
done

echo -e "\n=== 검증 완료 ==="
EOF

chmod +x verify-cluster-connectivity.sh
./verify-cluster-connectivity.sh
```

---

## 1. 시스템 기본 설정

### 1.1 RHEL 저장소 문제 해결

RHEL 서브스크립션 문제로 `yum repolist`가 비어있는 상황을 해결합니다.

```bash
# subscription-manager 비활성화
sudo systemctl disable rhsmcertd
sudo systemctl stop rhsmcertd

# 기존 저장소 설정 백업
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

# 저장소 확인
sudo dnf clean all && sudo dnf makecache
sudo dnf repolist
```

### 1.2 시스템 설정

```bash
# SELinux 비활성화
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# swap 비활성화
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 방화벽 설정 (테스트용 완전 비활성화)
sudo systemctl stop firewalld
sudo systemctl disable firewalld

# 커널 모듈 로드
sudo modprobe br_netfilter overlay
echo -e 'br_netfilter\noverlay' | sudo tee /etc/modules-load.d/k8s.conf

# 네트워크 설정
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
```

---

## 2. 컨테이너 런타임 설치

### 2.1 containerd 수동 설치

```bash
# 작업 디렉토리 생성
mkdir -p ~/containerd-install && cd ~/containerd-install

# containerd 바이너리 다운로드 (온라인 환경에서 미리 준비)
wget https://github.com/containerd/containerd/releases/download/v1.7.8/containerd-1.7.8-linux-amd64.tar.gz
wget https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz

# 바이너리 설치
sudo tar Cxzvf /usr/local containerd-1.7.8-linux-amd64.tar.gz
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.3.0.tgz

# 실행 권한 설정
sudo chmod +x /usr/local/bin/containerd*
sudo chmod +x /usr/local/sbin/runc
```

### 2.2 containerd 서비스 설정

```bash
# systemd 서비스 파일 생성
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
sudo mkdir -p /etc/containerd
sudo /usr/local/bin/containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 서비스 시작
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd
```

### 2.3 crictl 설치

```bash
# crictl 바이너리 다운로드 및 설치
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.29.0/crictl-v1.29.0-linux-amd64.tar.gz" | sudo tar -C /usr/local/bin -xz
sudo chmod +x /usr/local/bin/crictl

# crictl 설정
sudo tee /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 2
debug: false
EOF

# 설치 확인
crictl --version
sudo crictl version
```

---

## 3. Kubernetes 설치

### 3.1 Kubernetes 바이너리 설치

```bash
# 바이너리가 /usr/local/bin에 없는 경우 다운로드
cd ~/k8s-install
K8S_VERSION="v1.29.0"

# Kubernetes 바이너리 다운로드
wget https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet
wget https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubeadm
wget https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl

# 설치 및 권한 설정
chmod +x kubelet kubeadm kubectl
sudo mv kubelet kubeadm kubectl /usr/local/bin/

# 설치 확인
kubelet --version
kubeadm version
kubectl version --client
```

### 3.2 kubelet 시스템 서비스 설정

```bash
# kubelet 서비스 파일 생성
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

# kubelet 드롭인 디렉토리 및 설정
sudo mkdir -p /etc/systemd/system/kubelet.service.d

# kubeadm 설정
sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

# containerd 연동 설정
sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

# 필수 디렉토리 생성
sudo mkdir -p /etc/kubernetes/{pki,manifests}
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /var/lib/kubeadm
sudo mkdir -p /var/lib/etcd

# 서비스 활성화
sudo systemctl daemon-reload
sudo systemctl enable kubelet
```

### 3.3 누락된 패키지 설치

```bash
# socat과 conntrack 설치 시도
sudo dnf install -y socat conntrack-tools

# 설치 실패 시 수동 설치
if ! command -v socat &> /dev/null; then
    # socat RPM 다운로드 및 설치
    wget http://mirror.centos.org/centos/9-stream/AppStream/x86_64/os/Packages/socat-1.7.4.1-5.el9.x86_64.rpm
    sudo rpm -ivh socat-1.7.4.1-5.el9.x86_64.rpm --force --nodeps
fi

if ! command -v conntrack &> /dev/null; then
    # conntrack RPM 다운로드 및 설치
    wget http://mirror.centos.org/centos/9-stream/BaseOS/x86_64/os/Packages/conntrack-tools-1.4.7-2.el9.x86_64.rpm
    sudo rpm -ivh conntrack-tools-1.4.7-2.el9.x86_64.rpm --force --nodeps
fi
```

---

## 4. Kubernetes 클러스터 초기화

### 4.1 마스터 노드 클러스터 초기화

```bash
# 마스터 노드 IP 설정
MASTER_IP="10.10.10.99"
echo "Master IP: $MASTER_IP"

# kubeadm 설정 파일 생성
cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$MASTER_IP"
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
  - "$MASTER_IP"
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

# 메모리 부족 및 누락 패키지 오류 무시하고 클러스터 초기화 (테스트 환경)
sudo kubeadm init --config=/root/kubeadm-config.yaml \
  --ignore-preflight-errors=Mem,FileExisting-socat,FileExisting-conntrack \
  --upload-certs

# 조인 명령어 저장 (워커 노드에서 사용)
kubeadm token create --print-join-command > /root/worker-join-command.sh
chmod +x /root/worker-join-command.sh

echo "워커 노드 조인 명령어가 /root/worker-join-command.sh에 저장되었습니다."
cat /root/worker-join-command.sh
```

### 4.2 마스터 노드 kubectl 설정

```bash
# kubectl 설정 (root 사용자)
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 일반 사용자용 설정 (chris 사용자)
sudo mkdir -p /home/chris/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/chris/.kube/config
sudo chown chris:chris /home/chris/.kube/config

# kubectl 자동완성 설정
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
source ~/.bashrc

# 마스터 노드 초기 상태 확인 (워커 노드 조인 전)
kubectl get nodes
kubectl get pods -n kube-system
```

### 4.3 워커 노드 준비 및 조인

**각 워커 노드 (10.10.10.100, 10.10.10.103, 10.10.10.105)에서 수행:**

#### 워커 노드 사전 설정

```bash
# 워커 노드에서도 1-3단계의 모든 설정 완료 후:
# - RHEL 저장소 설정
# - 시스템 설정 (SELinux, swap, 방화벽, 커널 모듈)
# - containerd, crictl 설치
# - Kubernetes 바이너리 설치
# - kubelet 서비스 설정
# - 누락 패키지 설치

# kubelet 서비스 활성화 (아직 시작하지 않음)
sudo systemctl enable kubelet
```

#### 워커 노드 클러스터 조인

```bash
# 마스터 노드에서 조인 명령어 복사
# /root/worker-join-command.sh 내용을 각 워커 노드에서 실행

# 예시 (실제 토큰과 해시는 다를 수 있음):
sudo kubeadm join 10.10.10.99:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --ignore-preflight-errors=Mem,FileExisting-socat,FileExisting-conntrack \
  --cri-socket=unix:///run/containerd/containerd.sock
```

### 4.4 클러스터 상태 확인

```bash
# 마스터 노드에서 전체 클러스터 상태 확인
kubectl get nodes -o wide

# 예상 출력:
# NAME                   STATUS   ROLES           AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE   KERNEL-VERSION   CONTAINER-RUNTIME
# dover-rhel94-master    Ready    control-plane   5m    v1.29.0   10.10.10.99    <none>        RHEL 9.4   ...              containerd://1.7.8
# dover-rhel94-worker1   Ready    <none>          3m    v1.29.0   10.10.10.100   <none>        RHEL 9.4   ...              containerd://1.7.8
# dover-rhel94-worker2   Ready    <none>          3m    v1.29.0   10.10.10.103   <none>        RHEL 9.4   ...              containerd://1.7.8
# dover-rhel94-worker3   Ready    <none>          3m    v1.29.0   10.10.10.105   <none>        RHEL 9.4   ...              containerd://1.7.8

# 노드별 리소스 확인
kubectl describe nodes

# 클러스터 정보 확인
kubectl cluster-info
```

### 4.5 CNI 플러그인 설치 (Flannel)

```bash
# 마스터 노드에서 Flannel 설치
wget https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# Flannel 설치
kubectl apply -f kube-flannel.yml

# CNI 설치 확인 (모든 노드에서 Flannel Pod 실행 대기)
kubectl get pods -n kube-flannel

# 노드 상태 재확인 (Ready 상태 확인)
kubectl get nodes

# 예상 출력 (모든 노드가 Ready 상태):
# NAME                   STATUS   ROLES           AGE   VERSION
# dover-rhel94-master    Ready    control-plane   8m    v1.29.0
# dover-rhel94-worker1   Ready    <none>          6m    v1.29.0
# dover-rhel94-worker2   Ready    <none>          6m    v1.29.0
# dover-rhel94-worker3   Ready    <none>          6m    v1.29.0
```

### 4.6 클러스터 기본 검증

```bash
# 클러스터 기본 동작 검증 스크립트
cat <<'EOF' > verify-cluster-basic.sh
#!/bin/bash

echo "=== Kubernetes 클러스터 기본 검증 ==="

# 1. 노드 상태 확인
echo "1. 노드 상태:"
kubectl get nodes -o wide

# 2. 시스템 Pod 상태 확인
echo -e "\n2. 시스템 Pod 상태:"
kubectl get pods -n kube-system -o wide

# 3. CNI Pod 상태 확인
echo -e "\n3. CNI (Flannel) Pod 상태:"
kubectl get pods -n kube-flannel -o wide

# 4. 간단한 테스트 Pod 배포
echo -e "\n4. 테스트 Pod 배포:"
kubectl run test-nginx --image=nginx:latest --restart=Never

# 5. Pod가 워커 노드에 스케줄되는지 확인
echo -e "\n5. 테스트 Pod 상태:"
sleep 10
kubectl get pod test-nginx -o wide

# 6. 테스트 Pod 정리
echo -e "\n6. 테스트 Pod 정리:"
kubectl delete pod test-nginx

echo -e "\n=== 기본 검증 완료 ==="
EOF

chmod +x verify-cluster-basic.sh
./verify-cluster-basic.sh
```

---

## 5. Helm 설치

```bash
# Helm 바이너리 다운로드 및 설치
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# 또는 수동 설치
wget https://get.helm.sh/helm-v3.12.0-linux-amd64.tar.gz
tar -zxvf helm-v3.12.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/

# 설치 확인
helm version
```

---

## 6. 내부 레지스트리 설정 (폐쇄망 환경)

### 6.1 Harbor 설치 (내부 레지스트리)

```bash
# Harbor 네임스페이스 생성
kubectl create namespace harbor

# Harbor Helm 저장소 추가
helm repo add harbor https://helm.goharbor.io
helm repo update

# Harbor values 파일 생성 (마스터 노드 IP 사용)
cat <<EOF > harbor-values.yaml
expose:
  type: nodePort
  nodePort:
    ports:
      http:
        nodePort: 30002
      https:
        nodePort: 30003

externalURL: http://10.10.10.99:30002
harborAdminPassword: "Harbor12345"

persistence:
  enabled: true
  persistentVolumeClaim:
    registry:
      size: 10Gi
    chartmuseum:
      size: 5Gi
    jobservice:
      jobLog:
        size: 1Gi
      scanDataExports:
        size: 1Gi
    database:
      size: 5Gi
    redis:
      size: 1Gi
    trivy:
      size: 5Gi

# 리소스 제한 (저사양 환경)
core:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  # 마스터 노드에만 스케줄링
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

portal:
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 200m
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

database:
  internal:
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
    tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

redis:
  internal:
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
    tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
EOF

# Harbor 설치
helm install harbor harbor/harbor -n harbor -f harbor-values.yaml

# 설치 진행 상황 모니터링
kubectl get pods -n harbor -w
```

### 6.2 모든 노드에 내부 레지스트리 설정

**마스터 및 모든 워커 노드에서 수행:**

```bash
# containerd 설정에 내부 레지스트리 추가
sudo tee -a /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://10.10.10.99:30002/v2/docker.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
      endpoint = ["http://10.10.10.99:30002/v2/registry.k8s.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["http://10.10.10.99:30002/v2/quay.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["http://10.10.10.99:30002/v2/gcr.io"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."10.10.10.99:30002".tls]
      insecure_skip_verify = true
EOF

# containerd 재시작 (모든 노드에서)
sudo systemctl restart containerd

# kubelet 재시작 (모든 노드에서)
sudo systemctl restart kubelet
```

---

## 7. 애플리케이션 설치

### 7.1 cert-manager 설치 (Rancher 전제조건)

```bash
# cert-manager 네임스페이스 생성
kubectl create namespace cert-manager

# cert-manager CRDs 설치
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml

# cert-manager Helm 저장소 추가
helm repo add jetstack https://charts.jetstack.io
helm repo update

# cert-manager 설치
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.13.0
```

### 7.2 Rancher UI 설치

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
  --set bootstrapPassword=admin

# 설치 확인
kubectl get pods -n cattle-system

# 초기 비밀번호 확인
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}'
```

### 7.3 AWX 설치

```bash
# AWX 네임스페이스 생성
kubectl create namespace awx

# AWX Operator 설치 (간단한 방법)
kubectl apply -f https://raw.githubusercontent.com/ansible/awx-operator/devel/deploy/awx-operator.yaml -n awx

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
EOF

# 설치 확인 및 관리자 비밀번호 확인
kubectl get pods -n awx
kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx | base64 --decode
```

# Kafka 클러스터 생성 (워커 노드 분산 배치)
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
spec:
  kafka:
    version: 3.6.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 9094
        type: nodeport
        tls: false
        configuration:
          brokers:
          - broker: 0
            nodePort: 30090
          - broker: 1
            nodePort: 30091
          - broker: 2
            nodePort: 30092
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    storage:
      type: jbod
      volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        deleteClaim: false
    # 워커 노드에만 배치
    template:
      pod:
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
        tolerations: []
    resources:
      requests:
        memory: 512Mi
        cpu: 200m
      limits:
        memory: 1Gi
        cpu: 500m
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: false
    # 워커 노드에만 배치
    template:
      pod:
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
        tolerations: []
    resources:
      requests:
        memory: 512Mi
        cpu: 200m
      limits:
        memory: 1Gi
        cpu: 500m
  entityOperator:
    topicOperator: {}
    userOperator: {}
    template:
      pod:
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
EOF

# 설치 확인
kubectl get pods -n kafka -w
kubectl get svc -n kafka
```

---

## 8. 설치 검증 및 Pod 상태 확인

### 8.1 전체 클러스터 상태 확인

```bash
# 종합 클러스터 상태 확인 스크립트
cat <<'EOF' > verify-complete-cluster.sh
#!/bin/bash

echo "=== 완전한 클러스터 설치 상태 검증 ==="

# 1. 노드 상태 상세 확인
echo "1. 클러스터 노드 상태:"
kubectl get nodes -o wide
echo ""

# 2. 노드별 리소스 사용량
echo "2. 노드별 리소스 사용량:"
kubectl top nodes 2>/dev/null || echo "metrics-server가 설치되지 않음"
echo ""

# 3. 네임스페이스별 Pod 상태
echo "3. 네임스페이스별 Pod 상태:"

echo "  kube-system:"
kubectl get pods -n kube-system -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

echo ""
echo "  kube-flannel:"
kubectl get pods -n kube-flannel -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

echo ""
echo "  harbor:"
kubectl get pods -n harbor -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

echo ""
echo "  cattle-system (Rancher):"
kubectl get pods -n cattle-system -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

echo ""
echo "  awx:"
kubectl get pods -n awx -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

echo ""
echo "  kafka:"
kubectl get pods -n kafka -o wide | grep -E "(NAME|Running|Pending|Error|CrashLoopBackOff)"

# 4. 서비스 상태 확인
echo ""
echo "4. 주요 서비스 상태:"
kubectl get svc --all-namespaces | grep -E "(NAMESPACE|NodePort|LoadBalancer)"

# 5. PV/PVC 상태 확인
echo ""
echo "5. 저장소 상태:"
kubectl get pv,pvc --all-namespaces

# 6. 이벤트 확인 (최근 경고/에러)
echo ""
echo "6. 최근 클러스터 이벤트 (경고/에러):"
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | tail -20

echo ""
echo "=== 검증 완료 ==="
EOF

chmod +x verify-complete-cluster.sh
./verify-complete-cluster.sh
```

### 8.2 Pod 정상 상태 확인 스크립트

```bash
# Pod 정상 상태 상세 확인 스크립트
cat <<'EOF' > check-pod-health.sh
#!/bin/bash

echo "=== Pod 헬스 체크 ==="

check_namespace_pods() {
    local namespace=$1
    local app_name=$2
    
    echo "[$app_name] $namespace 네임스페이스:"
    
    # Pod 개수 확인
    total_pods=$(kubectl get pods -n $namespace --no-headers | wc -l)
    running_pods=$(kubectl get pods -n $namespace --no-headers | grep Running | wc -l)
    ready_pods=$(kubectl get pods -n $namespace --no-headers | awk '{if($2 ~ /^[0-9]+\/[0-9]+$/) {split($2,a,"/"); if(a[1]==a[2]) count++}} END {print count+0}')
    
    echo "  총 Pod: $total_pods, 실행 중: $running_pods, 준비 완료: $ready_pods"
    
    # 문제가 있는 Pod 확인
    problem_pods=$(kubectl get pods -n $namespace --no-headers | grep -v Running | grep -v Completed)
    if [ ! -z "$problem_pods" ]; then
        echo "  ⚠️  문제가 있는 Pod:"
        echo "$problem_pods" | while read line; do
            pod_name=$(echo $line | awk '{print $1}')
            status=$(echo $line | awk '{print $3}')
            echo "    - $pod_name: $status"
        done
    else
        echo "  ✅ 모든 Pod가 정상 상태"
    fi
    
    echo ""
}

# 각 네임스페이스별 확인
check_namespace_pods "kube-system" "Kubernetes 시스템"
check_namespace_pods "kube-flannel" "CNI (Flannel)"
check_namespace_pods "harbor" "Harbor 레지스트리"
check_namespace_pods "cattle-system" "Rancher UI"
check_namespace_pods "awx" "AWX"
check_namespace_pods "kafka" "Apache Kafka"

# 전체 요약
echo "=== 전체 요약 ==="
total_all_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
running_all_pods=$(kubectl get pods --all-namespaces --no-headers | grep Running | wc -l)

echo "전체 클러스터: $running_all_pods/$total_all_pods Pod가 실행 중"

if [ $running_all_pods -eq $total_all_pods ]; then
    echo "🎉 모든 Pod가 정상적으로 실행 중입니다!"
else
    echo "⚠️  일부 Pod에 문제가 있습니다. 개별 확인이 필요합니다."
fi

echo ""
echo "=== 헬스 체크 완료 ==="
EOF

chmod +x check-pod-health.sh
./check-pod-health.sh
```

### 8.3 노드별 Pod 분산 상태 확인

```bash
# 노드별 Pod 분산 확인 스크립트
cat <<'EOF' > check-pod-distribution.sh
#!/bin/bash

echo "=== 노드별 Pod 분산 상태 ==="

# 노드 목록 가져오기
nodes=$(kubectl get nodes --no-headers | awk '{print $1}')

for node in $nodes; do
    echo "[$node]"
    
    # 노드 타입 확인
    if kubectl get node $node -o jsonpath='{.metadata.labels}' | grep -q "control-plane"; then
        node_type="Master Node"
    else
        node_type="Worker Node"
    fi
    echo "  타입: $node_type"
    
    # 해당 노드의 Pod 개수
    pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node --no-headers | wc -l)
    echo "  실행 중인 Pod 수: $pod_count"
    
    # 네임스페이스별 Pod 분포
    echo "  네임스페이스별 분포:"
    kubectl get pods --all-namespaces --field-selector spec.nodeName=$node --no-headers | \
    awk '{print $1}' | sort | uniq -c | \
    while read count namespace; do
        echo "    $namespace: $count개"
    done
    
    echo ""
done

# 워커 노드 부하 분산 확인
echo "=== 워커 노드 부하 분산 분석 ==="
worker_nodes=$(kubectl get nodes --no-headers | grep -v master | grep -v control-plane | awk '{print $1}')

if [ ! -z "$worker_nodes" ]; then
    echo "워커 노드별 애플리케이션 Pod 분포:"
    for node in $worker_nodes; do
        app_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node --no-headers | \
                  grep -v -E "(kube-system|kube-flannel)" | wc -l)
        echo "  $node: $app_pods개 애플리케이션 Pod"
    done
else
    echo "워커 노드가 감지되지 않았습니다."
fi

echo ""
echo "=== 분산 상태 확인 완료 ==="
EOF

chmod +x check-pod-distribution.sh
./check-pod-distribution.sh
```

### 8.4 서비스 접속 정보

```bash
# 접속 정보 정리 스크립트
cat <<'EOF' > show-access-info.sh
#!/bin/bash

echo "=== 클러스터 서비스 접속 정보 ==="

# 클러스터 기본 정보
echo "1. 클러스터 정보:"
echo "  마스터 노드: 10.10.10.99 (dover-rhel94-master)"
echo "  워커 노드 1: 10.10.10.100 (dover-rhel94-worker1)"
echo "  워커 노드 2: 10.10.10.103 (dover-rhel94-worker2)" 
echo "  워커 노드 3: 10.10.10.105 (dover-rhel94-worker3)"
echo ""

# NodePort 서비스 확인
echo "2. 외부 접속 가능한 서비스:"
kubectl get svc --all-namespaces -o wide | grep NodePort | while read line; do
    namespace=$(echo $line | awk '{print $1}')
    service=$(echo $line | awk '{print $2}')
    ports=$(echo $line | awk '{print $6}')
    
    # NodePort 추출
    nodeport=$(echo $ports | grep -o '[0-9]\+' | tail -1)
    
    echo "  $service ($namespace):"
    echo "    접속 URL: http://10.10.10.99:$nodeport"
    echo "    모든 노드에서 접속 가능: 10.10.10.100:$nodeport, 10.10.10.103:$nodeport, 10.10.10.105:$nodeport"
done

echo ""
echo "3. 주요 서비스별 접속 정보:"

# Harbor
harbor_port=$(kubectl get svc -n harbor harbor-portal -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ ! -z "$harbor_port" ]; then
    echo "  🐳 Harbor (컨테이너 레지스트리):"
    echo "    URL: http://10.10.10.99:$harbor_port"
    echo "    계정: admin / Harbor12345"
fi

# Rancher
rancher_port=$(kubectl get svc -n cattle-system rancher -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ ! -z "$rancher_port" ]; then
    echo "  🐄 Rancher (Kubernetes 관리):"
    echo "    URL: https://10.10.10.99:$rancher_port"
    echo "    계정: admin / $(kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null)"
fi

# AWX
awx_port=$(kubectl get svc -n awx awx-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ ! -z "$awx_port" ]; then
    echo "  ⚙️  AWX (Ansible Tower):"
    echo "    URL: http://10.10.10.99:$awx_port"
    echo "    계정: admin / $(kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx 2>/dev/null | base64 --decode)"
fi

# Kafka
kafka_ports=$(kubectl get svc -n kafka | grep NodePort | grep kafka | awk '{print $5}')
if [ ! -z "$kafka_ports" ]; then
    echo "  📨 Apache Kafka:"
    echo "    브로커 엔드포인트: my-cluster-kafka-bootstrap.kafka.svc:9092 (클러스터 내부)"
    echo "    외부 접속 포트: $kafka_ports"
fi

echo ""
echo "4. kubectl 설정:"
echo "  설정 파일: ~/.kube/config"
echo "  클러스터 접속: kubectl cluster-info"

echo ""
echo "=== 접속 정보 확인 완료 ==="
EOF

chmod +x show-access-info.sh
./show-access-info.sh
```

### 8.5 최종 검증 대시보드

```bash
# 최종 종합 검증 대시보드
cat <<'EOF' > final-verification-dashboard.sh
#!/bin/bash

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Kubernetes 클러스터 최종 검증 대시보드                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

# 클러스터 기본 정보
echo ""
echo "🎯 클러스터 기본 정보:"
kubectl cluster-info --short 2>/dev/null || kubectl cluster-info

echo ""
echo "🏢 노드 현황:"
kubectl get nodes -o custom-columns="이름:.metadata.name,상태:.status.conditions[-1].type,역할:.metadata.labels.node-role\.kubernetes\.io/control-plane,IP:.status.addresses[0].address,버전:.status.nodeInfo.kubeletVersion"

echo ""
echo "📊 전체 Pod 현황:"
echo "네임스페이스별 Pod 수:"
kubectl get pods --all-namespaces --no-headers | awk '{print $1}' | sort | uniq -c | while read count ns; do
    printf "  %-20s: %2d개\n" "$ns" "$count"
done

echo ""
echo "🎯 주요 시스템 Pod 상태:"
important_pods="kube-apiserver kube-controller-manager kube-scheduler etcd coredns kube-flannel"
for pod_pattern in $important_pods; do
    status=$(kubectl get pods -A | grep $pod_pattern | head -1 | awk '{print $4}')
    if [ "$status" = "Running" ]; then
        printf "  %-25s: ✅ Running\n" "$pod_pattern"
    else
        printf "  %-25s: ❌ %s\n" "$pod_pattern" "$status"
    fi
done

echo ""
echo "🚀 애플리케이션 상태:"
apps=("harbor:Harbor" "cattle-system:Rancher" "awx:AWX" "kafka:Kafka")
for app in "${apps[@]}"; do
    ns=$(echo $app | cut -d: -f1)
    name=$(echo $app | cut -d: -f2)
    
    total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
    running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l)
    
    if [ $total -gt 0 ]; then
        if [ $running -eq $total ]; then
            printf "  %-15s: ✅ %d/%d Pod 실행 중\n" "$name" "$running" "$total"
        else
            printf "  %-15s: ⚠️  %d/%d Pod 실행 중\n" "$name" "$running" "$total"
        fi
    else
        printf "  %-15s: ❌ 설치되지 않음\n" "$name"
    fi
done

echo ""
echo "🌐 외부 접속 서비스:"
kubectl get svc --all-namespaces | grep NodePort | while read line; do
    ns=$(echo $line | awk '{print $1}')
    svc=$(echo $line | awk '{print $2}')
    port=$(echo $line | awk '{print $6}' | grep -o '[0-9]\+' | tail -1)
    printf "  %-20s: http://10.10.10.99:%s\n" "$svc ($ns)" "$port"
done

echo ""
echo "💾 저장소 현황:"
pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
pvc_count=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
echo "  PersistentVolume: $pv_count개"
echo "  PersistentVolumeClaim: $pvc_count개"

echo ""
echo "🎉 클러스터 준비 상태:"
node_ready=$(kubectl get nodes --no-headers | grep Ready | wc -l)
node_total=$(kubectl get nodes --no-headers | wc -l)

if [ $node_ready -eq $node_total ] && [ $node_total -eq 4 ]; then
    echo "  ✅ 모든 노드 ($node_ready/$node_total)가 Ready 상태"
    echo "  ✅ 클러스터가 완전히 준비되었습니다!"
else
    echo "  ⚠️  노드 상태: $node_ready/$node_total Ready"
    echo "  ⚠️  일부 노드에 문제가 있을 수 있습니다."
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                              검증 완료                                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
EOF

chmod +x final-verification-dashboard.sh
./final-verification-dashboard.sh
```

---

## 9. 문제 해결

### 8.1 전체 시스템 상태 확인

```bash
# 검증 스크립트 생성
cat <<'EOF' > verify-all-installations.sh
#!/bin/bash

echo "=== 전체 설치 상태 검증 ==="

# 1. Kubernetes 클러스터 상태
echo "1. Kubernetes 클러스터:"
kubectl get nodes -o wide

# 2. 시스템 Pod 상태
echo -e "\n2. 시스템 Pod 상태:"
kubectl get pods -n kube-system

# 3. 설치된 애플리케이션들
echo -e "\n3. 설치된 애플리케이션:"

echo "  Harbor:"
kubectl get pods -n harbor | head -5

echo "  Rancher:"
kubectl get pods -n cattle-system | head -5

echo "  AWX:"
kubectl get pods -n awx | head -5

echo "  Kafka:"
kubectl get pods -n kafka | head -5

# 4. 서비스 상태
echo -e "\n4. 주요 서비스:"
kubectl get svc --all-namespaces | grep -E "(harbor|rancher|awx|kafka)"

# 5. 시스템 리소스
echo -e "\n5. 시스템 리소스:"
kubectl top nodes 2>/dev/null || echo "metrics-server가 설치되지 않음"

echo -e "\n=== 검증 완료 ==="
EOF

chmod +x verify-all-installations.sh
./verify-all-installations.sh
```

### 8.2 접속 정보

```bash
# 접속 정보 출력
echo "=== 접속 정보 ==="
echo "Harbor: http://$NODE_IP:30002 (admin/Harbor12345)"
echo "Rancher: https://rancher.local (hosts 파일 설정 필요)"
echo "AWX: http://$NODE_IP:30080"
echo "Kafka: my-cluster-kafka-bootstrap.kafka.svc:9092"
echo ""
echo "kubectl 설정 완료"
echo "helm 설치 완료"
```

---

## 9. 문제 해결

### 9.1 일반적인 문제들

#### Pod가 Pending 상태
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events --sort-by=.metadata.creationTimestamp
```

#### 메모리 부족 문제
```bash
# 불필요한 Pod 정리
kubectl delete pod <pod-name> -n <namespace>

# 리소스 사용량 확인
kubectl top pods --all-namespaces
```

#### 이미지 Pull 실패
```bash
# containerd 상태 확인
sudo systemctl status containerd

# crictl로 직접 테스트
sudo crictl pull nginx:latest
```

### 9.2 로그 확인

```bash
# kubelet 로그
sudo journalctl -u kubelet -f

# containerd 로그
sudo journalctl -u containerd -f

# 특정 Pod 로그
kubectl logs <pod-name> -n <namespace>
```

---

## 10. 백업 및 복구

### 10.1 클러스터 백업

```bash
# etcd 백업
sudo ETCDCTL_API=3 etcdctl snapshot save backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 설정 파일 백업
sudo tar -czf k8s-config-backup.tar.gz /etc/kubernetes/
```

### 10.2 KVM 스냅샷 생성

```bash
# 호스트에서 VM 스냅샷 생성
sudo virsh snapshot-create-as dover-rhel94 "k8s-installed" "Kubernetes 설치 완료"
```

---

## 11. 추가 설정

### 11.1 Persistent Volume 설정

```bash
# 로컬 스토리지 클래스 생성
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
```

### 11.2 네트워크 정책 (선택사항)

```bash
# 기본 네트워크 정책 생성
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

---

이 가이드를 순서대로 따라하면 RHEL 9.4 폐쇄망 환경에서 Kubernetes와 모든 필요한 애플리케이션들을 성공적으로 설치할 수 있습니다.
