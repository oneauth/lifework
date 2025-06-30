#!/bin/bash
# 06-install-apps.sh
# 애플리케이션 설치 (마스터 노드에서 실행)

set -e

echo "=== Kubernetes 애플리케이션 설치 시작 ==="

# 마스터 노드 확인
NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
if [ "$NODE_IP" != "10.10.10.99" ]; then
    echo "❌ 이 스크립트는 마스터 노드(10.10.10.99)에서만 실행해야 합니다."
    exit 1
fi

# 클러스터 상태 확인
echo "클러스터 상태 확인 중..."
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ 클러스터에 연결할 수 없습니다."
    echo "04-init-cluster.sh를 먼저 실행하세요."
    exit 1
fi

# 모든 노드가 Ready인지 확인
ready_nodes=$(kubectl get nodes --no-headers | grep Ready | wc -l)
total_nodes=$(kubectl get nodes --no-headers | wc -l)

echo "노드 상태: $ready_nodes/$total_nodes Ready"
if [ $ready_nodes -lt $total_nodes ]; then
    echo "⚠️  모든 노드가 Ready 상태가 아닙니다."
    echo "계속 진행하시겠습니까? (y/N)"
    read -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Helm 설치
install_helm() {
    echo "1. Helm 설치 중..."
    
    if command -v helm &>/dev/null; then
        echo "✅ Helm이 이미 설치되어 있습니다: $(helm version --short)"
        return 0
    fi
    
    # Helm 설치
    if ping -c 1 8.8.8.8 &>/dev/null; then
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
    else
        echo "❌ 오프라인 환경에서는 Helm을 수동으로 설치해야 합니다."
        return 1
    fi
    
    echo "✅ Helm 설치 완료: $(helm version --short)"
}

# Harbor 설치
install_harbor() {
    echo "2. Harbor (컨테이너 레지스트리) 설치 중..."
    
    kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
    
    # Harbor Helm 저장소 추가
    helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
    helm repo update
    
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
    database:
      size: 5Gi
    redis:
      size: 1Gi

# 리소스 제한
core:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m

portal:
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 200m
EOF
    
    # Harbor 설치
    helm install harbor harbor/harbor -n harbor -f harbor-values.yaml
    
    echo "✅ Harbor 설치 시작됨 (완료까지 몇 분 소요)"
}

# cert-manager 설치
install_cert_manager() {
    echo "3. cert-manager 설치 중..."
    
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    
    # cert-manager CRDs 설치
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.crds.yaml
    
    # cert-manager Helm 저장소 추가
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update
    
    # cert-manager 설치
    helm install cert-manager jetstack/cert-manager \
      --namespace cert-manager \
      --version v1.13.0
    
    echo "✅ cert-manager 설치 완료"
}

# Rancher 설치
install_rancher() {
    echo "4. Rancher UI 설치 중..."
    
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Rancher Helm 저장소 추가
    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest 2>/dev/null || true
    helm repo update
    
    # Rancher values 파일 생성
    cat <<EOF > rancher-values.yaml
hostname: rancher.k8s.local
replicas: 1
bootstrapPassword: admin

# 서비스 타입 설정
service:
  type: NodePort
  ports:
    http: 30080
    https: 30443

# 리소스 제한
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
EOF
    
    # Rancher 설치
    helm install rancher rancher-latest/rancher \
      --namespace cattle-system \
      -f rancher-values.yaml
    
    echo "✅ Rancher 설치 시작됨"
}

# AWX 설치
install_awx() {
    echo "5. AWX 설치 중..."
    
    kubectl create namespace awx --dry-run=client -o yaml | kubectl apply -f -
    
    # AWX Operator 설치
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
  nodeport_port: 30081
  replicas: 1
  
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
    
    echo "✅ AWX 설치 시작됨"
}

# Kafka 설치
install_kafka() {
    echo "6. Apache Kafka 설치 중..."
    
    kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
    
    # Strimzi Operator 설치
    kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
    
    # Kafka 클러스터 생성
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
EOF
    
    echo "✅ Kafka 설치 시작됨"
}

# metrics-server 설치
install_metrics_server() {
    echo "7. metrics-server 설치 중..."
    
    # metrics-server 설치
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # TLS 검증 비활성화 (테스트 환경용)
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
    
    echo "✅ metrics-server 설치 완료"
}

# 설치 진행 상황 모니터링
monitor_installation() {
    echo ""
    echo "8. 설치 진행 상황 모니터링..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    for i in {1..30}; do
        echo "[$i/30] 설치 상태 확인 중..."
        
        # 각 네임스페이스별 Pod 상태
        echo "  Harbor: $(kubectl get pods -n harbor --no-headers 2>/dev/null | grep Running | wc -l)/$(kubectl get pods -n harbor --no-headers 2>/dev/null | wc -l) Running"
        echo "  Rancher: $(kubectl get pods -n cattle-system --no-headers 2>/dev/null | grep Running | wc -l)/$(kubectl get pods -n cattle-system --no-headers 2>/dev/null | wc -l) Running"
        echo "  AWX: $(kubectl get pods -n awx --no-headers 2>/dev/null | grep Running | wc -l)/$(kubectl get pods -n awx --no-headers 2>/dev/null | wc -l) Running"
        echo "  Kafka: $(kubectl get pods -n kafka --no-headers 2>/dev/null | grep Running | wc -l)/$(kubectl get pods -n kafka --no-headers 2>/dev/null | wc -l) Running"
        
        sleep 30
        clear
    done
}

# 설치 결과 확인
check_installation() {
    echo ""
    echo "9. 설치 결과 확인..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 각 애플리케이션별 상태 확인
    apps=("harbor:Harbor" "cattle-system:Rancher" "awx:AWX" "kafka:Kafka")
    for app in "${apps[@]}"; do
        ns=$(echo $app | cut -d: -f1)
        name=$(echo $app | cut -d: -f2)
        
        total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo "0")
        running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l || echo "0")
        
        printf "  %-15s: " "$name"
        if [ $total -gt 0 ]; then
            if [ $running -eq $total ]; then
                echo "✅ 정상 ($running/$total Pod)"
            else
                echo "⚠️  확인 필요 ($running/$total Pod)"
            fi
        else
            echo "❌ 설치되지 않음"
        fi
    done
}

# 접속 정보 출력
show_access_info() {
    echo ""
    echo "10. 접속 정보"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo "🌐 외부 접속 URL:"
    echo "  • Harbor: http://10.10.10.99:30002 (admin/Harbor12345)"
    echo "  • Rancher: http://10.10.10.99:30080 (admin/bootstrap-password)"
    echo "  • AWX: http://10.10.10.99:30081 (admin/auto-generated)"
    echo "  • Kafka: 10.10.10.99:30090-30092 (외부 접속용)"
    
    echo ""
    echo "🔑 초기 비밀번호 확인 방법:"
    echo "  • Rancher: kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}'"
    echo "  • AWX: kubectl get secret awx-admin-password -o jsonpath='{.data.password}' -n awx | base64 --decode"
}

# 메인 실행 부분
echo "애플리케이션 설치를 시작합니다."
echo "설치할 구성 요소: Helm, Harbor, cert-manager, Rancher, AWX, Kafka, metrics-server"
echo ""
echo "계속 진행하시겠습니까? (y/N)"
read -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "설치 취소됨"
    exit 1
fi

# 순차적으로 설치 실행
install_helm
sleep 5

install_harbor
sleep 10

install_cert_manager
sleep 15

install_rancher
sleep 10

install_awx
sleep 10

install_kafka
sleep 10

install_metrics_server
sleep 5

# 설치 모니터링 (선택사항)
echo ""
echo "설치 진행 상황을 모니터링하시겠습니까? (15분 소요) (y/N)"
read -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    monitor_installation
fi

# 최종 결과 확인
check_installation
show_access_info

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                        애플리케이션 설치 완료                                 ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📋 다음 단계:"
echo "1. ./verify-cluster.sh로 전체 상태 확인"
echo "2. 각 애플리케이션 접속 테스트"
echo "3. 필요시 ./backup/backup-cluster.sh로 백업 생성"
echo ""
echo "💡 참고:"
echo "- 모든 애플리케이션이 완전히 시작되기까지 10-15분 소요될 수 있습니다"
echo "- Pod 상태는 'kubectl get pods --all-namespaces'로 확인 가능합니다"
