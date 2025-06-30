# RHEL 9.4 Kubernetes 클러스터 설치 프로젝트

## 📁 프로젝트 구조

```
k8s-rhel94-installation/
├── README.md                    # 이 파일
├── docs/
│   ├── installation-guide.md   # 상세 설치 가이드
│   ├── troubleshooting.md      # 문제 해결 가이드
│   └── network-info.md         # 네트워크 구성 정보
├── scripts/
│   ├── 01-system-setup.sh      # 시스템 기본 설정
│   ├── 02-install-containerd.sh # Containerd 설치
│   ├── 03-install-kubernetes.sh # Kubernetes 설치
│   ├── 04-init-cluster.sh      # 클러스터 초기화
│   ├── 05-join-workers.sh      # 워커 노드 조인
│   └── 06-install-apps.sh      # 애플리케이션 설치
├── config/
│   ├── kubeadm-config.yaml     # kubeadm 설정
│   ├── harbor-values.yaml      # Harbor 설정
│   ├── rancher-values.yaml     # Rancher 설정
│   └── kafka-cluster.yaml      # Kafka 설정
├── verification/
│   ├── verify-cluster.sh       # 클러스터 검증
│   ├── check-pods.sh          # Pod 상태 확인
│   └── health-check.sh        # 헬스체크
├── monitoring/
│   ├── monitor-cluster.sh      # 실시간 모니터링
│   └── daily-check.sh         # 일일 점검
├── backup/
│   ├── backup-cluster.sh       # 클러스터 백업
│   └── backup-etcd.sh         # etcd 백업
└── maintenance/
    ├── cleanup.sh             # 정리 작업
    └── update-cluster.sh      # 클러스터 업데이트
```

## 🎯 빠른 시작

### 1. 환경 정보
- **OS**: RHEL 9.4 (KVM 가상머신)
- **클러스터**: 1 Master + 3 Worker 노드
- **네트워크**: 10.10.10.0/24 (폐쇄망)

### 2. 노드 구성
| 역할 | 호스트명 | IP 주소 |
|------|----------|---------|
| Master | dover-rhel94-master | 10.10.10.99 |
| Worker1 | dover-rhel94-worker1 | 10.10.10.100 |
| Worker2 | dover-rhel94-worker2 | 10.10.10.103 |
| Worker3 | dover-rhel94-worker3 | 10.10.10.105 |

### 3. 설치 순서

#### 모든 노드에서 공통 작업:
```bash
# 1. 시스템 기본 설정
./scripts/01-system-setup.sh

# 2. Containerd 설치
./scripts/02-install-containerd.sh

# 3. Kubernetes 바이너리 설치
./scripts/03-install-kubernetes.sh
```

#### 마스터 노드에서:
```bash
# 4. 클러스터 초기화
./scripts/04-init-cluster.sh

# 5. 애플리케이션 설치
./scripts/06-install-apps.sh
```

#### 워커 노드에서:
```bash
# 5. 워커 노드 조인
./scripts/05-join-workers.sh
```

### 4. 설치 검증
```bash
# 클러스터 상태 확인
./verification/verify-cluster.sh

# Pod 상태 확인
./verification/check-pods.sh
```

## 🌐 접속 정보

| 서비스 | URL | 계정 |
|--------|-----|------|
| Harbor | http://10.10.10.99:30002 | admin/Harbor12345 |
| Rancher | http://10.10.10.99:30080 | admin/bootstrap-secret |
| AWX | http://10.10.10.99:30081 | admin/awx-admin-password |
| Kafka | 10.10.10.99:30090-30092 | - |

## 📊 모니터링

```bash
# 실시간 모니터링
./monitoring/monitor-cluster.sh

# 일일 점검
./monitoring/daily-check.sh
```

## 💾 백업

```bash
# 전체 클러스터 백업
./backup/backup-cluster.sh

# etcd만 백업
./backup/backup-etcd.sh
```

## 🔧 문제 해결

상세한 문제 해결 방법은 `docs/troubleshooting.md`를 참조하세요.

## 📝 라이선스

이 프로젝트는 MIT 라이선스 하에 제공됩니다.

---

## 다음 파일들

각 스크립트와 설정 파일들이 개별적으로 제공됩니다:

1. **scripts/** - 설치 스크립트들
2. **config/** - 설정 파일들  
3. **verification/** - 검증 스크립트들
4. **monitoring/** - 모니터링 도구들
5. **backup/** - 백업 스크립트들
6. **docs/** - 상세 문서들
