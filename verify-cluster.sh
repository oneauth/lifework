#!/bin/bash
# verify-cluster.sh
# 클러스터 상태 종합 검증

set -e

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    Kubernetes 클러스터 상태 검증                              ║"
echo "║                         $(date +"%Y-%m-%d %H:%M:%S")                           ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

# 색상 설정
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 체크 함수
check_status() {
    local item="$1"
    local command="$2"
    local expected="$3"
    
    printf "%-50s: " "$item"
    
    local result=$(eval $command 2>/dev/null)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ] && [[ "$result" =~ $expected ]]; then
        echo -e "${GREEN}✅ 정상${NC}"
        return 0
    else
        echo -e "${RED}❌ 이상 ($result)${NC}"
        return 1
    fi
}

# 1. 클러스터 기본 정보
echo ""
echo -e "${BLUE}🎯 클러스터 기본 정보${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# kubectl 연결 확인
if kubectl cluster-info &>/dev/null; then
    echo -e "${GREEN}✅ kubectl 연결: 정상${NC}"
    kubectl cluster-info --short
else
    echo -e "${RED}❌ kubectl 연결: 실패${NC}"
    exit 1
fi

# 2. 노드 상태 확인
echo ""
echo -e "${BLUE}🏢 노드 상태${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl get nodes -o custom-columns="이름:.metadata.name,상태:.status.conditions[-1].type,역할:.metadata.labels.node-role\.kubernetes\.io/control-plane,IP:.status.addresses[0].address,버전:.status.nodeInfo.kubeletVersion"

# 노드 개수 확인
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep Ready | wc -l)

printf "%-50s: " "노드 상태"
if [ $READY_NODES -eq 4 ] && [ $TOTAL_NODES -eq 4 ]; then
    echo -e "${GREEN}✅ 모든 노드 Ready ($READY_NODES/$TOTAL_NODES)${NC}"
else
    echo -e "${YELLOW}⚠️  일부 노드 문제 ($READY_NODES/$TOTAL_NODES)${NC}"
fi

# 3. 시스템 Pod 상태
echo ""
echo -e "${BLUE}⚙️ 시스템 Pod 상태${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 중요한 시스템 Pod들 확인
important_pods=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd" "coredns")
for pod_pattern in "${important_pods[@]}"; do
    pod_status=$(kubectl get pods -n kube-system | grep $pod_pattern | head -1 | awk '{print $3}' 2>/dev/null || echo "NotFound")
    printf "%-50s: " "$pod_pattern"
    if [ "$pod_status" = "Running" ]; then
        echo -e "${GREEN}✅ Running${NC}"
    else
        echo -e "${RED}❌ $pod_status${NC}"
    fi
done

# 4. CNI 상태 확인
echo ""
echo -e "${BLUE}🌐 CNI (네트워크) 상태${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Flannel Pod 확인
flannel_pods=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | wc -l || echo "0")
flannel_running=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep Running | wc -l || echo "0")

printf "%-50s: " "Flannel Pod"
if [ $flannel_pods -gt 0 ] && [ $flannel_running -eq $flannel_pods ]; then
    echo -e "${GREEN}✅ 정상 ($flannel_running/$flannel_pods)${NC}"
else
    echo -e "${RED}❌ 문제 ($flannel_running/$flannel_pods)${NC}"
fi

# 5. 애플리케이션 상태
echo ""
echo -e "${BLUE}🚀 애플리케이션 상태${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

apps=("harbor:Harbor" "cattle-system:Rancher" "awx:AWX" "kafka:Kafka")
for app in "${apps[@]}"; do
    ns=$(echo $app | cut -d: -f1)
    name=$(echo $app | cut -d: -f2)
    
    total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l || echo "0")
    running=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l || echo "0")
    
    printf "%-50s: " "$name"
    if [ $total -gt 0 ]; then
        if [ $running -eq $total ]; then
            echo -e "${GREEN}✅ 정상 ($running/$total Pod)${NC}"
        else
            echo -e "${YELLOW}⚠️  확인 필요 ($running/$total Pod)${NC}"
        fi
    else
        echo -e "${RED}❌ 설치되지 않음${NC}"
    fi
done

# 6. 외부 접속 서비스
echo ""
echo -e "${BLUE}🌐 외부 접속 서비스${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl get svc --all-namespaces | grep NodePort | while read line; do
    ns=$(echo $line | awk '{print $1}')
    svc=$(echo $line | awk '{print $2}')
    port=$(echo $line | awk '{print $6}' | grep -o '[0-9]\+' | tail -1)
    printf "  %-30s: http://10.10.10.99:%s\n" "$svc ($ns)" "$port"
done

# 7. 리소스 사용량
echo ""
echo -e "${BLUE}📊 리소스 사용량${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# metrics-server 확인
if kubectl top nodes &>/dev/null; then
    kubectl top nodes
else
    echo "metrics-server가 설치되지 않아 리소스 사용량을 확인할 수 없습니다."
fi

# 8. 저장소 상태
echo ""
echo -e "${BLUE}💾 저장소 상태${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l || echo "0")
pvc_count=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")

echo "  PersistentVolume: $pv_count개"
echo "  PersistentVolumeClaim: $pvc_count개"

# 9. 문제가 있는 Pod 확인
echo ""
echo -e "${BLUE}⚠️ 문제가 있는 Pod${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

problem_pods=$(kubectl get pods --all-namespaces --no-headers | grep -v Running | grep -v Completed 2>/dev/null || echo "")
if [ -z "$problem_pods" ]; then
    echo -e "${GREEN}✅ 모든 Pod가 정상 상태입니다.${NC}"
else
    echo -e "${RED}다음 Pod들에 문제가 있습니다:${NC}"
    echo "$problem_pods" | while read line; do
        echo "  - $line"
    done
fi

# 10. 최근 이벤트
echo ""
echo -e "${BLUE}📝 최근 클러스터 이벤트 (경고/에러)${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

recent_events=$(kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | grep -E "(Warning|Error)" | tail -5 || echo "")
if [ -z "$recent_events" ]; then
    echo -e "${GREEN}✅ 최근 경고/에러 이벤트가 없습니다.${NC}"
else
    echo "$recent_events"
fi

# 11. 전체 요약
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                              검증 요약                                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
running_pods=$(kubectl get pods --all-namespaces --no-headers | grep Running | wc -l)

echo "📊 전체 현황:"
echo "  • 노드: $READY_NODES/$TOTAL_NODES Ready"
echo "  • Pod: $running_pods/$total_pods Running"
echo "  • 네임스페이스: $(kubectl get ns --no-headers | wc -l)개"

if [ $READY_NODES -eq 4 ] && [ $running_pods -eq $total_pods ]; then
    echo ""
    echo -e "${GREEN}🎉 클러스터가 완전히 정상 상태입니다! 🎉${NC}"
    exit 0
else
    echo ""
    echo -e "${YELLOW}⚠️  일부 구성 요소에 문제가 있습니다. 개별 확인이 필요합니다.${NC}"
    exit 1
fi
