# Harbor K3s 설치 및 Helm 차트 관리 가이드

**환경 구성:**
- **Linux 서버**: Podman + K3s 설치됨, 인터넷 불가
- **Windows 클라이언트**: Helm CLI만 설치됨, 인터넷 가능

---

## 1. 🪟 Windows에서 필요한 파일들 준비

### 1.1 Harbor Helm 차트 다운로드

```powershell
# Harbor Helm 저장소 추가 및 차트 다운로드
helm repo add harbor https://helm.goharbor.io
helm repo update

# Harbor 차트를 로컬에 다운로드 (최신 버전)
helm pull harbor/harbor --version 1.13.0

# 의존성 차트들도 함께 다운로드
helm dependency update harbor-1.13.0.tgz
```

### 1.2 Harbor 설정 파일 생성

```powershell
# harbor-values.yaml 생성
@'
# Harbor 설정 파일
expose:
  type: nodePort
  tls:
    enabled: false
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 30080
      https:
        port: 443
        nodePort: 30443

# 외부 접속 URL (실제 서버 IP로 변경)
externalURL: http://YOUR_SERVER_IP:30080

# Harbor 관리자 비밀번호
harborAdminPassword: "Harbor12345"

# 데이터 저장 설정
persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:
      storageClass: "local-path"  # k3s 기본 스토리지 클래스
      size: 20Gi
    chartmuseum:
      storageClass: "local-path"
      size: 5Gi
    database:
      storageClass: "local-path"
      size: 1Gi
    redis:
      storageClass: "local-path"
      size: 1Gi

# Helm 차트 저장소 기능 활성화
chartmuseum:
  enabled: true

# 리소스 제한 (작은 환경에 맞게 조정)
core:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m

registry:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m

database:
  internal:
    resources:
      requests:
        memory: 256Mi
        cpu: 100m
      limits:
        memory: 512Mi
        cpu: 500m
'@ | Out-File -FilePath harbor-values.yaml -Encoding UTF8
```

### 1.3 외부 Helm 차트들 다운로드

```powershell
# 자주 사용할 저장소들 추가
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 필요한 차트들 다운로드
$charts = @(
    @{repo="bitnami"; name="nginx"},
    @{repo="bitnami"; name="mysql"}, 
    @{repo="bitnami"; name="postgresql"},
    @{repo="bitnami"; name="redis"},
    @{repo="bitnami"; name="mongodb"},
    @{repo="bitnami"; name="apache"},
    @{repo="ingress-nginx"; name="ingress-nginx"},
    @{repo="jetstack"; name="cert-manager"}
)

foreach ($chart in $charts) {
    Write-Host "Downloading $($chart.repo)/$($chart.name)..."
    helm pull "$($chart.repo)/$($chart.name)"
}

# 다운로드된 파일들 확인
Write-Host "`n다운로드된 파일들:"
dir *.tgz | Format-Table Name, Length
```

---

## 2. 🐧 Linux 서버에서 Harbor 설치 (K3s에 배포)

### 2.1 파일 전송 확인 및 네임스페이스 생성

```bash
# Windows에서 전송받은 파일들 확인
ls -la *.tgz *.yaml

# Harbor용 네임스페이스 생성
kubectl create namespace harbor

# k3s 스토리지 클래스 확인
kubectl get storageclass
```

### 2.2 Harbor Helm 차트 설치 (오프라인)

```bash
# 로컬 harbor 차트 파일로 설치
helm install harbor ./harbor-1.13.0.tgz \
  --namespace harbor \
  --values harbor-values.yaml \
  --wait \
  --timeout 10m

# 설치 진행 상황 확인
kubectl get pods -n harbor -w
```

### 2.3 Harbor 서비스 확인

```bash
# 모든 Pod가 Running 상태가 될 때까지 대기
kubectl wait --for=condition=ready pod --all -n harbor --timeout=900s

# Harbor 서비스 상태 확인
kubectl get all -n harbor

# NodePort 서비스 확인
kubectl get svc -n harbor | grep NodePort

# Harbor 접속 테스트
curl -I http://localhost:30080
```

### 2.4 방화벽 설정 (필요시)

```bash
# 포트 열기
sudo ufw allow 30080
sudo ufw allow 30443
sudo ufw status
```

---

## 3. 🪟 Windows에서 Harbor 설정 및 차트 업로드

### 3.1 Harbor 웹 UI에서 프로젝트 생성

1. 브라우저에서 `http://YOUR_SERVER_IP:30080` 접속
2. 계정: `admin` / 비밀번호: `Harbor12345`
3. "Projects" → "NEW PROJECT" 클릭
4. Project Name: `helm-charts`
5. Access Level: `Public` 선택
6. "OK" 클릭

### 3.2 Helm Push 플러그인 설치

```powershell
# Helm push 플러그인 설치
helm plugin install https://github.com/chartmuseum/helm-push

# 플러그인 설치 확인
helm plugin list
```

### 3.3 Harbor 저장소 추가 및 차트 업로드

```powershell
# Harbor를 Helm 저장소로 추가
helm repo add harbor-charts http://YOUR_SERVER_IP:30080/chartrepo/helm-charts

# 저장소 목록 확인
helm repo list

# 모든 다운로드된 차트를 Harbor에 업로드
Get-ChildItem "*.tgz" | Where-Object { $_.Name -notlike "harbor-*" } | ForEach-Object {
    Write-Host "Uploading $($_.Name) to Harbor..."
    try {
        helm cm-push $_.Name harbor-charts --username admin --password Harbor12345
        Write-Host "✅ Successfully uploaded: $($_.Name)"
    }
    catch {
        Write-Host "❌ Failed to upload $($_.Name): $($_.Exception.Message)"
    }
}

# 업로드 확인
helm repo update
helm search repo harbor-charts
```

### 3.4 자동화 스크립트 생성

```powershell
# sync-to-harbor.ps1 파일 생성
@'
param(
    [string]$HarborIP = "YOUR_SERVER_IP",
    [string]$HarborPort = "30080",
    [string]$Username = "admin",
    [string]$Password = "Harbor12345"
)

$harborUrl = "http://$HarborIP`:$HarborPort/chartrepo/helm-charts"

Write-Host "🚀 Harbor 차트 동기화 시작..."
Write-Host "Harbor URL: $harborUrl"

# 외부 저장소 업데이트
Write-Host "📦 외부 저장소 업데이트 중..."
helm repo update

# 업데이트할 차트 목록
$chartsToUpdate = @(
    @{repo="bitnami"; chart="nginx"},
    @{repo="bitnami"; chart="mysql"},
    @{repo="bitnami"; chart="postgresql"},
    @{repo="bitnami"; chart="redis"},
    @{repo="ingress-nginx"; chart="ingress-nginx"}
)

foreach ($item in $chartsToUpdate) {
    $chartName = "$($item.repo)/$($item.chart)"
    Write-Host "⬇️  다운로드 중: $chartName"
    
    # 기존 파일 삭제
    Remove-Item "$($item.chart)-*.tgz" -ErrorAction SilentlyContinue
    
    # 최신 버전 다운로드
    helm pull $chartName
    
    # Harbor에 업로드
    $chartFile = Get-ChildItem "$($item.chart)-*.tgz" | Select-Object -First 1
    if ($chartFile) {
        Write-Host "⬆️  업로드 중: $($chartFile.Name)"
        helm cm-push $chartFile.Name harbor-charts --username $Username --password $Password
        Remove-Item $chartFile.Name
        Write-Host "✅ 완료: $($item.chart)"
    } else {
        Write-Host "❌ 실패: $($item.chart) 파일을 찾을 수 없음"
    }
}

Write-Host "🎉 Harbor 차트 동기화 완료!"
'@ | Out-File -FilePath sync-to-harbor.ps1 -Encoding UTF8

# 스크립트 실행 예시
# .\sync-to-harbor.ps1 -HarborIP "192.168.1.100"
```

---

## 4. 🐧 Linux 서버에서 Harbor 차트 사용

### 4.1 Harbor 저장소 로컬 접근 설정

```bash
# Harbor 서비스 IP 확인
kubectl get svc -n harbor harbor-harbor-core

# 로컬에서 Harbor 저장소 추가
helm repo add harbor-charts http://localhost:30080/chartrepo/helm-charts

# 또는 클러스터 내부 DNS 사용
# helm repo add harbor-charts http://harbor-harbor-core.harbor.svc.cluster.local/chartrepo/helm-charts

# 저장소 업데이트
helm repo update

# 사용 가능한 차트 확인
helm search repo harbor-charts
```

### 4.2 Harbor에서 차트 배포

```bash
# nginx 배포
helm install my-nginx harbor-charts/nginx \
  --namespace default \
  --set service.type=NodePort \
  --set service.nodePorts.http=30081

# mysql 배포
helm install my-mysql harbor-charts/mysql \
  --namespace default \
  --set auth.rootPassword=mypassword \
  --set primary.service.type=NodePort \
  --set primary.service.nodePorts.mysql=30306

# PostgreSQL 배포
helm install my-postgres harbor-charts/postgresql \
  --namespace default \
  --set auth.postgresPassword=mypassword \
  --set primary.service.type=NodePort

# 배포된 애플리케이션 확인
helm list
kubectl get pods
kubectl get svc
```

### 4.3 배포 상태 확인

```bash
# 특정 배포 상태 확인
helm status my-nginx
helm status my-mysql

# Pod 로그 확인
kubectl logs -l app.kubernetes.io/name=nginx
kubectl logs -l app.kubernetes.io/name=mysql

# 서비스 엔드포인트 확인
kubectl get endpoints
```

---

## 5. 🔧 Harbor 관리 및 트러블슈팅

### 🐧 Linux에서 Harbor 관리

```bash
# Harbor Pod 상태 확인
kubectl get pods -n harbor

# Harbor 로그 확인
kubectl logs -n harbor -l app=harbor-core
kubectl logs -n harbor -l app=harbor-registry

# Harbor 재시작 (필요시)
kubectl rollout restart deployment harbor-harbor-core -n harbor

# Harbor 스토리지 사용량 확인
kubectl get pvc -n harbor
df -h

# Harbor 서비스 삭제 (필요시)
# helm uninstall harbor -n harbor
```

### 🪟 Windows에서 연결 확인

```powershell
# Harbor 연결 테스트
Test-NetConnection -ComputerName YOUR_SERVER_IP -Port 30080

# Harbor API 테스트
$cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:Harbor12345"))
$headers = @{"Authorization" = "Basic $cred"}
try {
    $response = Invoke-RestMethod -Uri "http://YOUR_SERVER_IP:30080/api/v2.0/projects" -Headers $headers
    Write-Host "✅ Harbor API 연결 성공"
    $response | Format-Table
} catch {
    Write-Host "❌ Harbor API 연결 실패: $($_.Exception.Message)"
}

# Helm 저장소 상태 확인
helm repo update harbor-charts
helm search repo harbor-charts --devel
```

---

## 6. 📋 체크리스트

### ✅ Windows 작업 체크리스트

- [ ] Harbor Helm 차트 다운로드 완료
- [ ] harbor-values.yaml 파일 생성
- [ ] 외부 Helm 차트들 다운로드 완료
- [ ] Linux 서버로 파일 전송 완료
- [ ] Helm push 플러그인 설치
- [ ] Harbor 웹 UI에서 helm-charts 프로젝트 생성
- [ ] Harbor 저장소 추가 및 차트 업로드 완료

### ✅ Linux 서버 작업 체크리스트

- [ ] K3s 클러스터 정상 동작 확인
- [ ] harbor 네임스페이스 생성
- [ ] Harbor Helm 차트 설치 완료
- [ ] 모든 Harbor Pod가 Running 상태
- [ ] Harbor 웹 UI 접속 가능 (포트 30080)
- [ ] Harbor 저장소를 로컬에서 접근 가능
- [ ] 차트 배포 테스트 완료

---

## 7. 🚀 일반적인 워크플로우

### 새로운 차트 추가 시

1. **Windows에서:**
   ```powershell
   # 새 차트 다운로드
   helm pull bitnami/wordpress
   
   # Harbor에 업로드
   helm cm-push wordpress-*.tgz harbor-charts --username admin --password Harbor12345
   ```

2. **Linux에서:**
   ```bash
   # 저장소 업데이트
   helm repo update harbor-charts
   
   # 새 차트 확인
   helm search repo harbor-charts/wordpress
   
   # 배포
   helm install my-wordpress harbor-charts/wordpress
   ```

### Harbor 업그레이드 시

```bash
# Harbor 차트 업그레이드
helm upgrade harbor ./harbor-1.14.0.tgz \
  --namespace harbor \
  --values harbor-values.yaml
```

---

## 8. 🔗 유용한 명령어 모음

### Harbor 상태 확인

```bash
# 전체 Harbor 상태 한 번에 확인
kubectl get all -n harbor
kubectl get pvc -n harbor
kubectl top pod -n harbor
```

### 차트 검색 및 정보

```bash
# Harbor에서 사용 가능한 모든 차트 보기
helm search repo harbor-charts

# 특정 차트의 상세 정보
helm show chart harbor-charts/nginx
helm show values harbor-charts/mysql
```

### 배포 관리

```bash
# 모든 Helm 릴리스 확인
helm list --all-namespaces

# 특정 릴리스 업그레이드
helm upgrade my-nginx harbor-charts/nginx --set replicas=3

# 릴리스 롤백
helm rollback my-nginx 1
```

---

**이제 Podman + K3s 환경에서 Harbor가 Pod로 실행되고, Windows에서는 Helm CLI만으로 차트를 관리할 수 있습니다!** 🚀