#!/bin/bash
# backup-cluster.sh
# Kubernetes 클러스터 전체 백업

set -e

# 백업 디렉토리 설정
BACKUP_BASE_DIR="/backup/k8s-cluster"
BACKUP_DIR="$BACKUP_BASE_DIR/$(date +%Y%m%d_%H%M%S)"
BACKUP_NAME="k8s-cluster-backup-$(date +%Y%m%d_%H%M%S)"

echo "=== Kubernetes 클러스터 백업 시작 ==="
echo "백업 디렉토리: $BACKUP_DIR"

# 백업 디렉토리 생성
mkdir -p $BACKUP_DIR/{etcd,manifests,configs,helm,logs}

# 클러스터 연결 확인
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ 클러스터에 연결할 수 없습니다."
    exit 1
fi

echo "✅ 클러스터 연결 확인 완료"

# 1. etcd 백업
backup_etcd() {
    echo "1. etcd 백업 중..."
    
    # etcd Pod 확인
    etcd_pod=$(kubectl get pods -n kube-system | grep etcd | head -1 | awk '{print $1}')
    if [ -z "$etcd_pod" ]; then
        echo "❌ etcd Pod를 찾을 수 없습니다."
        return 1
    fi
    
    # etcd 스냅샷 생성
    kubectl exec -n kube-system $etcd_pod -- etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        snapshot save /var/lib/etcd/backup.db
    
    # etcd 백업 파일 복사
    kubectl cp kube-system/$etcd_pod:/var/lib/etcd/backup.db $BACKUP_DIR/etcd/etcd-snapshot.db
    
    # etcd 백업 검증
    kubectl exec -n kube-system $etcd_pod -- etcdctl \
        --write-out=table snapshot status /var/lib/etcd/backup.db > $BACKUP_DIR/etcd/snapshot-status.txt
    
    echo "✅ etcd 백업 완료"
}

# 2. 클러스터 매니페스트 백업
backup_manifests() {
    echo "2. 클러스터 매니페스트 백업 중..."
    
    # 모든 리소스 백업
    kubectl get all --all-namespaces -o yaml > $BACKUP_DIR/manifests/all-resources.yaml
    
    # 네임스페이스별 상세 백업
    for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
        echo "  네임스페이스 백업: $ns"
        mkdir -p $BACKUP_DIR/manifests/namespaces/$ns
        
        # 모든 리소스
        kubectl get all -n $ns -o yaml > $BACKUP_DIR/manifests/namespaces/$ns/all.yaml 2>/dev/null || true
        
        # ConfigMap
        kubectl get configmaps -n $ns -o yaml > $BACKUP_DIR/manifests/namespaces/$ns/configmaps.yaml 2>/dev/null || true
        
        # Secret
        kubectl get secrets -n $ns -o yaml > $BACKUP_DIR/manifests/namespaces/$ns/secrets.yaml 2>/dev/null || true
        
        # PVC
        kubectl get pvc -n $ns -o yaml > $BACKUP_DIR/manifests/namespaces/$ns/pvc.yaml 2>/dev/null || true
        
        # Ingress
        kubectl get ingress -n $ns -o yaml > $BACKUP_DIR/manifests/namespaces/$ns/ingress.yaml 2>/dev/null || true
    done
    
    # 클러스터 수준 리소스
    kubectl get nodes -o yaml > $BACKUP_DIR/manifests/nodes.yaml
    kubectl get pv -o yaml > $BACKUP_DIR/manifests/persistent-volumes.yaml
    kubectl get storageclass -o yaml > $BACKUP_DIR/manifests/storage-classes.yaml
    kubectl get clusterroles -o yaml > $BACKUP_DIR/manifests/cluster-roles.yaml
    kubectl get clusterrolebindings -o yaml > $BACKUP_DIR/manifests/cluster-role-bindings.yaml
    kubectl get crd -o yaml > $BACKUP_DIR/manifests/custom-resource-definitions.yaml
    
    echo "✅ 매니페스트 백업 완료"
}

# 3. 설정 파일 백업
backup_configs() {
    echo "3. 설정 파일 백업 중..."
    
    # Kubernetes 설정 (마스터 노드에서)
    if [ -d "/etc/kubernetes" ]; then
        sudo cp -r /etc/kubernetes $BACKUP_DIR/configs/ 2>/dev/null || true
    fi
    
    # kubelet 설정
    if [ -d "/var/lib/kubelet" ]; then
        sudo cp -r /var/lib/kubelet $BACKUP_DIR/configs/ 2>/dev/null || true
    fi
    
    # containerd 설정
    if [ -f "/etc/containerd/config.toml" ]; then
        sudo cp /etc/containerd/config.toml $BACKUP_DIR/configs/ 2>/dev/null || true
    fi
    
    # crictl 설정
    if [ -f "/etc/crictl.yaml" ]; then
        sudo cp /etc/crictl.yaml $BACKUP_DIR/configs/ 2>/dev/null || true
    fi
    
    # systemd 서비스 파일들
    mkdir -p $BACKUP_DIR/configs/systemd
    sudo cp /etc/systemd/system/kubelet.service $BACKUP_DIR/configs/systemd/ 2>/dev/null || true
    sudo cp -r /etc/systemd/system/kubelet.service.d $BACKUP_DIR/configs/systemd/ 2>/dev/null || true
    sudo cp /etc/systemd/system/containerd.service $BACKUP_DIR/configs/systemd/ 2>/dev/null || true
    
    echo "✅ 설정 파일 백업 완료"
}

# 4. Helm 릴리즈 백업
backup_helm() {
    echo "4. Helm 릴리즈 백업 중..."
    
    if ! command -v helm &> /dev/null; then
        echo "⚠️  Helm이 설치되지 않음 - Helm 백업 생략"
        return 0
    fi
    
    # Helm 릴리즈 목록
    helm list --all-namespaces > $BACKUP_DIR/helm/releases.txt
    
    # 각 릴리즈의 values 백업
    helm list --all-namespaces --output json | jq -r '.[] | "\(.name) \(.namespace)"' | while read name namespace; do
        echo "  Helm 릴리즈 백업: $name (네임스페이스: $namespace)"
        mkdir -p $BACKUP_DIR/helm/values/$namespace
        
        # Values 파일 백업
        helm get values $name -n $namespace > $BACKUP_DIR/helm/values/$namespace/$name-values.yaml 2>/dev/null || true
        
        # 매니페스트 백업
        helm get manifest $name -n $namespace > $BACKUP_DIR/helm/values/$namespace/$name-manifest.yaml 2>/dev/null || true
        
        # 릴리즈 정보 백업
        helm get all $name -n $namespace > $BACKUP_DIR/helm/values/$namespace/$name-all.yaml 2>/dev/null || true
    done
    
    echo "✅ Helm 백업 완료"
}

# 5. 로그 백업
backup_logs() {
    echo "5. 중요 로그 백업 중..."
    
    # 클러스터 정보
    kubectl cluster-info > $BACKUP_DIR/logs/cluster-info.txt
    kubectl version > $BACKUP_DIR/logs/version.txt
    kubectl get nodes -o wide > $BACKUP_DIR/logs/nodes.txt
    kubectl get pods --all-namespaces -o wide > $BACKUP_DIR/logs/all-pods.txt
    kubectl get svc --all-namespaces > $BACKUP_DIR/logs/all-services.txt
    kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp > $BACKUP_DIR/logs/events.txt
    
    # 시스템 Pod 로그 (최근 1시간)
    echo "  시스템 Pod 로그 수집 중..."
    for pod in $(kubectl get pods -n kube-system -o name | head -10); do
        pod_name=$(echo $pod | cut -d'/' -f2)
        kubectl logs -n kube-system $pod_name --since=1h > $BACKUP_DIR/logs/system-$pod_name.log 2>/dev/null || true
    done
    
    # 애플리케이션 Pod 로그 (최근 1시간)
    for ns in harbor cattle-system awx kafka; do
        if kubectl get namespace $ns &>/dev/null; then
            echo "  $ns 네임스페이스 로그 수집 중..."
            mkdir -p $BACKUP_DIR/logs/$ns
            
            for pod in $(kubectl get pods -n $ns -o name 2>/dev/null | head -5); do
                pod_name=$(echo $pod | cut -d'/' -f2)
                kubectl logs -n $ns $pod_name --since=1h > $BACKUP_DIR/logs/$ns/$pod_name.log 2>/dev/null || true
            done
        fi
    done
    
    echo "✅ 로그 백업 완료"
}

# 6. 백업 정보 파일 생성
create_backup_info() {
    echo "6. 백업 정보 파일 생성 중..."
    
    cat <<EOF > $BACKUP_DIR/backup-info.txt
Kubernetes 클러스터 백업 정보
============================

백업 시간: $(date)
백업 이름: $BACKUP_NAME
백업 경로: $BACKUP_DIR

클러스터 정보:
- 컨텍스트: $(kubectl config current-context)
- 서버: $(kubectl cluster-info | head -1)
- Kubernetes 버전: $(kubectl version --short --client)

노드 정보:
$(kubectl get nodes --no-headers | wc -l)개 노드
$(kubectl get nodes --no-headers | grep Ready | wc -l)개 Ready 상태

네임스페이스:
$(kubectl get namespaces --no-headers | wc -l)개 네임스페이스

Pod 상태:
전체: $(kubectl get pods --all-namespaces --no-headers | wc -l)개
실행 중: $(kubectl get pods --all-namespaces --no-headers | grep Running | wc -l)개

백업 내용:
- etcd 스냅샷
- 모든 Kubernetes 리소스 매니페스트
- 설정 파일 (kubelet, containerd 등)
- Helm 릴리즈 정보
- 최근 로그 (1시간)

백업 파일 구조:
├── etcd/                    # etcd 스냅샷
├── manifests/               # Kubernetes 매니페스트
│   ├── namespaces/         # 네임스페이스별 리소스
│   ├── nodes.yaml          # 노드 정보
│   └── ...                 # 기타 클러스터 리소스
├── configs/                 # 설정 파일들
├── helm/                    # Helm 릴리즈 정보
└── logs/                    # 로그 파일들

복구 방법:
1. etcd 복구: etcdctl snapshot restore
2. 매니페스트 적용: kubectl apply -f manifests/
3. Helm 릴리즈 복구: helm install

주의사항:
- 이 백업은 특정 시점의 스냅샷입니다
- 복구 시 현재 클러스터 상태가 덮어쓰일 수 있습니다
- 복구 전 현재 상태를 백업하는 것을 권장합니다
EOF
    
    echo "✅ 백업 정보 파일 생성 완료"
}

# 7. 백업 압축
compress_backup() {
    echo "7. 백업 압축 중..."
    
    cd $BACKUP_BASE_DIR
    tar -czf $BACKUP_NAME.tar.gz $(basename $BACKUP_DIR)
    
    # 압축 파일 크기 확인
    backup_size=$(du -h $BACKUP_NAME.tar.gz | cut -f1)
    echo "✅ 백업 압축 완료: $BACKUP_NAME.tar.gz ($backup_size)"
    
    # 압축되지 않은 디렉토리 제거 확인
    echo "압축되지 않은 백업 디렉토리를 제거하시겠습니까? (y/N)"
    read -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf $BACKUP_DIR
        echo "✅ 임시 백업 디렉토리 제거 완료"
    fi
}

# 8. 백업 검증
verify_backup() {
    echo "8. 백업 검증 중..."
    
    # 압축 파일 무결성 확인
    if tar -tzf $BACKUP_BASE_DIR/$BACKUP_NAME.tar.gz >/dev/null 2>&1; then
        echo "✅ 백업 파일 무결성 확인 완료"
    else
        echo "❌ 백업 파일 손상 감지"
        return 1
    fi
    
    # 주요 파일 존재 확인
    temp_dir=$(mktemp -d)
    tar -xzf $BACKUP_BASE_DIR/$BACKUP_NAME.tar.gz -C $temp_dir
    
    backup_content_dir="$temp_dir/$(basename $BACKUP_DIR)"
    
    echo "백업 내용 검증:"
    
    # etcd 스냅샷 확인
    if [ -f "$backup_content_dir/etcd/etcd-snapshot.db" ]; then
        echo "  ✅ etcd 스냅샷"
    else
        echo "  ❌ etcd 스냅샷 누락"
    fi
    
    # 매니페스트 확인
    if [ -f "$backup_content_dir/manifests/all-resources.yaml" ]; then
        echo "  ✅ 클러스터 매니페스트"
    else
        echo "  ❌ 클러스터 매니페스트 누락"
    fi
    
    # 설정 파일 확인
    if [ -d "$backup_content_dir/configs" ]; then
        echo "  ✅ 설정 파일"
    else
        echo "  ❌ 설정 파일 누락"
    fi
    
    # 백업 정보 파일 확인
    if [ -f "$backup_content_dir/backup-info.txt" ]; then
        echo "  ✅ 백업 정보 파일"
    else
        echo "  ❌ 백업 정보 파일 누락"
    fi
    
    # 임시 디렉토리 정리
    rm -rf $temp_dir
    
    echo "✅ 백업 검증 완료"
}

# 9. 백업 정리 (오래된 백업 삭제)
cleanup_old_backups() {
    echo "9. 오래된 백업 정리 중..."
    
    # 30일 이상 된 백업 파일 찾기
    old_backups=$(find $BACKUP_BASE_DIR -name "k8s-cluster-backup-*.tar.gz" -mtime +30 2>/dev/null || true)
    
    if [ -z "$old_backups" ]; then
        echo "✅ 정리할 오래된 백업이 없습니다"
        return 0
    fi
    
    echo "30일 이상 된 백업 파일:"
    echo "$old_backups"
    echo ""
    echo "이 파일들을 삭제하시겠습니까? (y/N)"
    read -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$old_backups" | xargs rm -f
        echo "✅ 오래된 백업 파일 삭제 완료"
    else
        echo "오래된 백업 파일 보존"
    fi
}

# 메인 실행 부분
echo "Kubernetes 클러스터 전체 백업을 시작합니다."
echo "백업 위치: $BACKUP_DIR"
echo ""
echo "계속 진행하시겠습니까? (y/N)"
read -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "백업 취소됨"
    exit 1
fi

# 백업 디렉토리 생성
mkdir -p $BACKUP_BASE_DIR

# 순차적으로 백업 실행
backup_etcd
backup_manifests
backup_configs
backup_helm
backup_logs
create_backup_info
compress_backup
verify_backup
cleanup_old_backups

# 최종 결과 출력
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        클러스터 백업 완료                                     ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 백업 파일: $BACKUP_BASE_DIR/$BACKUP_NAME.tar.gz"
echo "📊 백업 크기: $(du -h $BACKUP_BASE_DIR/$BACKUP_NAME.tar.gz | cut -f1)"
echo "🕐 백업 시간: $(date)"
echo ""
echo "💡 복구 방법:"
echo "1. 백업 파일 압축 해제: tar -xzf $BACKUP_NAME.tar.gz"
echo "2. etcd 복구 스크립트 실행"
echo "3. 매니페스트 적용: kubectl apply -f manifests/"
echo "4. Helm 릴리즈 복구"
echo ""
echo "⚠️  중요: 복구 시 현재 클러스터 데이터가 덮어쓰일 수 있습니다."
