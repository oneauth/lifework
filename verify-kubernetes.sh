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
if [ $
