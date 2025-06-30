#!/bin/bash
# monitor-cluster.sh
# 실시간 클러스터 모니터링 대시보드

# 색상 설정
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 모니터링 함수
show_dashboard() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    Kubernetes 클러스터 실시간 모니터링                        ║${NC}"
    echo -e "${CYAN}║                         $(date +"%Y-%m-%d %H:%M:%S")                           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    # 1. 클러스터 기본 정보
    echo ""
    echo -e "${BLUE}🎯 클러스터 정보${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl cluster-info --short 2>/dev/null | head -3
    
    # 2. 노드 상태
    echo ""
    echo -e "${BLUE}🏢 노드 상태${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 노드별 상태 및 리소스
    kubectl get nodes -o custom-columns="노드:.metadata.name,상태:.status.conditions[-1].type,역할:.metadata.labels.node-role\.kubernetes\.io/control-plane,IP:.status.addresses[0].address" 2>/dev/null
    
    # 리소스 사용량 (metrics-server가 있는 경우)
    echo ""
    if kubectl top nodes &>/dev/null; then
        echo -e "${PURPLE}📊 노드 리소스 사용량${NC}"
        kubectl top nodes
    else
        echo -e "${YELLOW}⚠️  metrics-server 없음 - 리소스 사용량 확인 불가${NC}"
    fi
    
    # 3. 네임스페이스별 Pod 상태
    echo ""
    echo -e "${BLUE}📦 네임스페이스별 Pod 현황${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 네임스페이스별 집계
    echo "네임스페이스          전체  실행중  대기중  오류"
    echo "────────────────────────────────────────────"
    
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '
    {
        ns[$1]++
        if ($4 == "Running") running[$1]++
        else if ($4 == "Pending") pending[$1]++
        else if ($4 ~ /Error|CrashLoopBackOff|Failed/) error[$1]++
        else other[$1]++
    }
    END {
        for (namespace in ns) {
            printf "%-20s %3d    %3d    %3d   %3d\n", 
                namespace, 
                ns[namespace], 
                running[namespace] + 0, 
                pending[namespace] + 0, 
                error[namespace] + 0
        }
    }'
    
    # 4. 주요 시스템 Pod 상태
    echo ""
    echo -e "${BLUE}⚙️ 중요 시스템 Pod${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    important_pods=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd" "coredns")
    for pod_pattern in "${important_pods[@]}"; do
        status=$(kubectl get pods -n kube-system 2>/dev/null | grep $pod_pattern | head -1 | awk '{print $3}' || echo "NotFound")
        printf "%-25s: " "$pod_pattern"
        case $status in
            "Running")
                echo -e "${GREEN}✅ Running${NC}"
                ;;
            "NotFound")
                echo -e "${RED}❌ Not Found${NC}"
                ;;
            *)
                echo -e "${YELLOW}⚠️  $status${NC}"
                ;;
        esac
    done
    
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
        
        printf "%-25s: " "$name"
        if [ $total -gt 0 ]; then
            if [ $running -eq $total ]; then
                echo -e "${GREEN}✅ $running/$total Running${NC}"
            else
                echo -e "${YELLOW}⚠️  $running/$total Running${NC}"
            fi
        else
            echo -e "${RED}❌ Not Installed${NC}"
        fi
    done
    
    # 6. 문제가 있는 Pod
    echo ""
    echo -e "${BLUE}⚠️ 문제가 있는 Pod${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    problem_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -v Running | grep -v Completed | head -5)
    if [ -z "$problem_pods" ]; then
        echo -e "${GREEN}✅ 모든 Pod가 정상 상태입니다${NC}"
    else
        echo -e "${RED}문제가 있는 Pod들:${NC}"
        echo "$problem_pods" | while read line; do
            echo "  $line"
        done
    fi
    
    # 7. 최근 이벤트
    echo ""
    echo -e "${BLUE}📝 최근 이벤트 (경고/에러)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    recent_events=$(kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp 2>/dev/null | grep -E "(Warning|Error)" | tail -3)
    if [ -z "$recent_events" ]; then
        echo -e "${GREEN}✅ 최근 경고/에러 이벤트 없음${NC}"
    else
        echo "$recent_events"
    fi
    
    # 8. 외부 서비스 상태
    echo ""
    echo -e "${BLUE}🌐 외부 접속 서비스${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    kubectl get svc --all-namespaces 2>/dev/null | grep NodePort | while read line; do
        ns=$(echo $line | awk '{print $1}')
        svc=$(echo $line | awk '{print $2}')
        port=$(echo $line | awk '{print $6}' | grep -o '[0-9]\+' | tail -1)
        printf "  %-20s: http://10.10.10.99:%s\n" "$svc" "$port"
    done
    
    # 9. 통계 요약
    echo ""
    echo -e "${BLUE}📊 전체 통계${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
    running_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep Running | wc -l)
    total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep Ready | wc -l)
    
    echo "  노드: $ready_nodes/$total_nodes Ready"
    echo "  Pod: $running_pods/$total_pods Running"
    echo "  네임스페이스: $(kubectl get ns --no-headers 2>/dev/null | wc -l)개"
    
    # 10. 제어 정보
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}새로고침: 30초마다 | 종료: Ctrl+C | 시간: $(date +"%H:%M:%S")${NC}"
}

# 메인 실행
echo "Kubernetes 클러스터 실시간 모니터링을 시작합니다..."
echo "종료하려면 Ctrl+C를 누르세요."
echo ""

# kubectl 연결 확인
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ 클러스터에 연결할 수 없습니다."
    echo "kubectl 설정을 확인하세요."
    exit 1
fi

# 신호 처리
trap 'echo -e "\n\n모니터링을 종료합니다."; exit 0' INT

# 무한 루프로 모니터링
while true; do
    show_dashboard
    sleep 30
done
