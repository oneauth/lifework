# 온프레미스 Kafka 4.0 KRaft + Strimzi 설치 가이드

## 1. 사전 요구사항

### 1.1 시스템 요구사항
```bash
# Kubernetes 클러스터
- Kubernetes 1.25+
- 워커 노드 최소 3개
- 각 노드당 최소 4GB RAM, 2 CPU
- 각 노드당 100GB 이상 디스크

# 네트워크 요구사항
- NodePort 범위: 30000-32767
- 외부 접근용 포트: 32000-32003
- 내부 통신 포트: 9092, 9093
```

### 1.2 DNS 설정 (권장)
```bash
# /etc/hosts 또는 DNS 서버에 설정
192.168.1.10 kafka-broker-01.company.local
192.168.1.11 kafka-broker-02.company.local  
192.168.1.12 kafka-broker-03.company.local
192.168.1.100 kafka-lb.company.local  # HAProxy 서버
```

## 2. Strimzi Operator 설치

### 2.1 네임스페이스 생성
```bash
# Kafka 전용 네임스페이스 생성
kubectl create namespace kafka

# Strimzi Operator 네임스페이스 생성
kubectl create namespace strimzi-system
```

### 2.2 Strimzi Operator 배포
```bash
# Strimzi Operator 최신 버전 다운로드
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/latest/download/strimzi-cluster-operator-0.43.0.yaml \
  -o strimzi-cluster-operator.yaml

# 네임스페이스 수정 (모든 네임스페이스 모니터링)
sed -i 's/namespace: .*/namespace: strimzi-system/' strimzi-cluster-operator.yaml
sed -i 's/STRIMZI_NAMESPACE/STRIMZI_NAMESPACE\n        - "*"/' strimzi-cluster-operator.yaml

# Operator 설치
kubectl apply -f strimzi-cluster-operator.yaml -n strimzi-system

# 설치 확인
kubectl get pods -n strimzi-system
kubectl logs -n strimzi-system deployment/strimzi-cluster-operator
```

### 2.3 Operator 상태 확인
```bash
# Operator 정상 동작 확인
kubectl get deployment strimzi-cluster-operator -n strimzi-system
kubectl get crd | grep kafka
```

## 3. 스토리지 클래스 설정

### 3.1 로컬 스토리지 클래스 생성
```yaml
# production-data-class.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
```

### 3.2 PersistentVolume 생성 (각 노드별)
```yaml
# prod-kafka-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-0
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /data/kafka-0
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker-node-1
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-1
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /data/kafka-1
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker-node-2
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-2
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /data/kafka-2
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker-node-3
```

### 3.3 스토리지 디렉터리 준비
```bash
# 각 워커 노드에서 실행
sudo mkdir -p /data/kafka-{0,1,2}
sudo chown -R 1001:1001 /data/kafka-*
sudo chmod 755 /data/kafka-*

# 스토리지 적용
kubectl apply -f local-storage-class.yaml
kubectl apply -f kafka-pv.yaml
```

## 4. Kafka 클러스터 구성

### 4.1 KafkaUser 생성 (SCRAM-SHA-512)
```yaml
# kafka-user.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: production-admin
  labels:
    strimzi.io/cluster: kafka-prod
  namespace: kafka
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      # 모든 토픽에 대한 관리자 권한
      - resource:
          type: topic
          name: "*"
        operations: ["Read", "Write", "Create", "Delete", "Alter", "Describe"]
      # 클러스터 관리 권한
      - resource:
          type: cluster
        operations: ["Alter", "AlterConfigs", "ClusterAction", "Create"]
      # 컨슈머 그룹 관리
      - resource:
          type: group
          name: "*"
        operations: ["Read", "Delete"]
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: prod-producer
  labels:
    strimzi.io/cluster: my-cluster
  namespace: kafka
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: "*"
        operations: ["Write", "Create", "Describe"]
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: prod-consumer
  labels:
    strimzi.io/cluster: my-cluster
  namespace: kafka
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: "*"
        operations: ["Read", "Describe"]
      - resource:
          type: group
          name: "*"
        operations: ["Read"]
```

### 4.2 Kafka 클러스터 정의
```yaml
# kafka-cluster.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
spec:
  kafka:
    version: 3.9.0  # 4.0.0 출시 후 변경
    replicas: 3
    listeners:
      # 내부 클러스터 통신
      - name: plain
        port: 9092
        type: internal
        tls: false
      # 외부 접근용 (NodePort)
      - name: external
        port: 9094
        type: nodeport
        tls: true
        authentication:
          type: scram-sha-512
        configuration:
          preferredNodePortAddressType: InternalIP
          bootstrap:
            nodePort: 32000
            annotations:
              service.kubernetes.io/external-load-balancer: "false"
          brokers:
            - broker: 0
              nodePort: 32001
              advertisedHost: "kafka-node-1.company.local"
            - broker: 1
              nodePort: 32002
              advertisedHost: "kafka-node-2.company.local"
            - broker: 2
              nodePort: 32003
              advertisedHost: "kafka-node-3.company.local"
    # KRaft 모드 설정
    config:
      # 메타데이터 버전 (KRaft 사용)
      metadata.version: 3.8-IV0
      
      # 로그 설정
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      log.retention.check.interval.ms: 300000
      log.cleanup.policy: delete
      
      # 복제 설정
      default.replication.factor: 3
      min.insync.replicas: 2
      
      # 네트워크 설정
      socket.send.buffer.bytes: 102400
      socket.receive.buffer.bytes: 102400
      socket.request.max.bytes: 104857600
      
      # 브로커 설정
      num.network.threads: 8
      num.io.threads: 8
      num.recovery.threads.per.data.dir: 1
      
      # 압축 설정
      compression.type: lz4
      
      # 배치 설정
      batch.size: 16384
      linger.ms: 5
      
      # 보안 설정
      ssl.endpoint.identification.algorithm: HTTPS
      
    storage:
      type: jbod
      volumes:
      - id: 0
        type: persistent-claim
        size: 100Gi
        deleteClaim: false
        class: local-storage
    
    # 리소스 제한
    resources:
      requests:
        memory: 2Gi
        cpu: "1"
      limits:
        memory: 4Gi
        cpu: "2"
    
    # JVM 힙 설정
    jvmOptions:
      -Xms: 2g
      -Xmx: 2g
      -XX:
        UseG1GC: true
        MaxGCPauseMillis: 20
        InitiatingHeapOccupancyPercent: 35
        ExplicitGCInvokesConcurrent: true
        UseStringDeduplication: true
    
    # 로그 설정
    logging:
      type: inline
      loggers:
        kafka.root.logger.level: INFO
        log4j.logger.org.apache.kafka: INFO
        log4j.logger.kafka.request.logger: WARN
        log4j.logger.kafka.network.Processor: OFF
        log4j.logger.kafka.server.KafkaApis: OFF
        log4j.logger.kafka.network.RequestChannel$: WARN
        log4j.logger.kafka.controller: TRACE
        log4j.logger.kafka.log.LogCleaner: INFO
        log4j.logger.state.change.logger: TRACE
        log4j.logger.kafka.authorizer.logger: WARN

    # 메트릭 설정
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: prod-kafka-metrics
          key: kafka-metrics-config.yml

  # EntityOperator (Topic & User 관리)
  entityOperator:
    topicOperator:
      watchedNamespace: kafka
      reconciliationIntervalSeconds: 90
      logging:
        type: inline
        loggers:
          rootLogger.level: INFO
      resources:
        requests:
          memory: 512Mi
          cpu: "0.1"
        limits:
          memory: 512Mi
          cpu: "0.5"
    userOperator:
      watchedNamespace: kafka
      reconciliationIntervalSeconds: 120
      logging:
        type: inline
        loggers:
          rootLogger.level: INFO
      resources:
        requests:
          memory: 512Mi
          cpu: "0.1"
        limits:
          memory: 512Mi
          cpu: "0.5"

  # Kafka Exporter (메트릭)
  kafkaExporter:
    topicRegex: ".*"
    groupRegex: ".*"
    resources:
      requests:
        cpu: 200m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 128Mi
```

### 4.3 메트릭 설정
```yaml
# kafka-metrics-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-metrics
  namespace: kafka
data:
  kafka-metrics-config.yml: |
    lowercaseOutputName: true
    lowercaseOutputLabelNames: true
    rules:
    # Kafka broker metrics
    - pattern: kafka.server<type=(.+), name=(.+)PerSec, topic=(.+)><>Count
      name: kafka_server_$1_$2_total
      type: COUNTER
      labels:
        topic: "$3"
    - pattern: kafka.server<type=(.+), name=(.+)PerSec><>Count
      name: kafka_server_$1_$2_total
      type: COUNTER
    # Kafka network metrics
    - pattern: kafka.network<type=(.+), name=(.+)><>Value
      name: kafka_network_$1_$2
      type: GAUGE
    # Kafka log metrics
    - pattern: kafka.log<type=(.+), name=(.+), topic=(.+), partition=(.+)><>Value
      name: kafka_log_$1_$2
      type: GAUGE
      labels:
        topic: "$3"
        partition: "$4"
```

## 5. 클러스터 배포

### 5.1 단계별 배포
```bash
# 1. 메트릭 ConfigMap 생성
kubectl apply -f kafka-metrics-config.yaml

# 2. Kafka 클러스터 생성
kubectl apply -f kafka-cluster.yaml

# 3. 배포 상태 확인
kubectl get kafka my-cluster -n kafka -w

# 4. Pod 상태 확인
kubectl get pods -n kafka

# 5. 로그 확인
kubectl logs kafka-prod-kafka-0 -n kafka -f
```

### 5.2 사용자 계정 생성
```bash
# 사용자 생성
kubectl apply -f kafka-user.yaml

# 사용자 시크릿 확인
kubectl get secret kafka-admin -n kafka -o jsonpath='{.data.password}' | base64 -d
kubectl get secret kafka-producer -n kafka -o jsonpath='{.data.password}' | base64 -d
kubectl get secret kafka-consumer -n kafka -o jsonpath='{.data.password}' | base64 -d
```

## 6. 외부 로드밸런서 구성 (HAProxy)

### 6.1 HAProxy 설정
```bash
# haproxy.cfg
global
    daemon
    log stdout local0 info
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# 통계 페이지
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE

# Kafka Bootstrap 서버 (9092)
frontend kafka_bootstrap
    bind *:9092
    default_backend kafka_bootstrap_backend

backend kafka_bootstrap_backend
    balance roundrobin
    option tcp-check
    tcp-check connect
    server kafka-0 kafka-node-1.company.local:32000 check
    server kafka-1 kafka-node-2.company.local:32000 check
    server kafka-2 kafka-node-3.company.local:32000 check

# 개별 브로커 접근
frontend kafka_broker_0
    bind *:32001
    default_backend kafka_broker_0_backend

backend kafka_broker_0_backend
    server kafka-0 kafka-node-1.company.local:32001 check

frontend kafka_broker_1
    bind *:32002
    default_backend kafka_broker_1_backend

backend kafka_broker_1_backend
    server kafka-1 kafka-node-2.company.local:32002 check

frontend kafka_broker_2
    bind *:32003
    default_backend kafka_broker_2_backend

backend kafka_broker_2_backend
    server kafka-2 kafka-node-3.company.local:32003 check
```

### 6.2 HAProxy 배포 (Docker)
```bash
# Docker Compose로 HAProxy 실행
# docker-compose.yml
version: '3.8'
services:
  haproxy:
    image: haproxy:2.8
    container_name: kafka-haproxy
    ports:
      - "9092:9092"
      - "32001:32001"
      - "32002:32002"
      - "32003:32003"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: unless-stopped
    networks:
      - kafka-network

networks:
  kafka-network:
    driver: bridge
```

## 7. 연결 테스트

### 7.1 클러스터 상태 확인
```bash
# Service 확인
kubectl get svc -n kafka

# NodePort 포트 확인
kubectl get svc kafka-prod-kafka-external-bootstrap -n kafka

# 인증서 확인
kubectl get secret kafka-prod-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

### 7.2 Kafka 클라이언트 테스트
```bash
# 클라이언트 Properties 파일 생성
cat > client.properties << EOF
bootstrap.servers=kafka-lb.company.local:9092
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="$(kubectl get secret kafka-admin -n kafka -o jsonpath='{.data.password}' | base64 -d)";
ssl.truststore.location=./truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=
EOF

# Truststore 생성
keytool -import -file ca.crt -alias ca -keystore truststore.jks -storepass changeit -noprompt

# 토픽 생성 테스트
kafka-topics.sh --bootstrap-server haproxy-server:9092 \
  --command-config client.properties \
  --create --topic orders-topic --partitions 3 --replication-factor 3

# 메시지 전송 테스트
echo "Hello Kafka 4.0 KRaft!" | kafka-console-producer.sh \
  --bootstrap-server haproxy-server:9092 \
  --producer.config client.properties \
  --topic test-topic

# 메시지 수신 테스트
kafka-console-consumer.sh \
  --bootstrap-server haproxy-server:9092 \
  --consumer.config client.properties \
  --topic test-topic --from-beginning
```

## 8. 모니터링 설정

### 8.1 Prometheus 메트릭 수집
```yaml
# prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
    - job_name: 'kafka'
      static_configs:
      - targets: ['my-cluster-kafka-0.kafka-prod-kafka-brokers.kafka.svc.cluster.local:9404']
      - targets: ['my-cluster-kafka-1.my-cluster-kafka-brokers.kafka.svc.cluster.local:9404']
      - targets: ['my-cluster-kafka-2.my-cluster-kafka-brokers.kafka.svc.cluster.local:9404']
    - job_name: 'kafka-exporter'
      static_configs:
      - targets: ['kafka-prod-kafka-exporter.kafka.svc.cluster.local:9308']
```

### 8.2 알람 설정
```yaml
# kafka-alerts.yaml
groups:
- name: kafka.rules
  rules:
  - alert: KafkaBrokerDown
    expr: kafka_server_kafkaserver_brokerstate != 3
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Kafka broker is down"
      description: "Kafka broker {{ $labels.instance }} is down"
  
  - alert: KafkaHighProducerError
    expr: rate(kafka_server_brokertopicmetrics_failedfetchrequestspersec_total[5m]) > 10
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "High Kafka producer error rate"
      description: "Kafka topic {{ $labels.topic }} has high error rate"
```

## 9. 백업 및 운영

### 9.1 정기 백업 스크립트
```bash
#!/bin/bash
# kafka-backup.sh

BACKUP_DIR="/backup/kafka"
DATE=$(date +%Y%m%d_%H%M%S)

# 토픽 목록 백업
kubectl exec -n kafka my-cluster-kafka-0 -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --list > $BACKUP_DIR/topics_$DATE.txt

# 설정 백업
kubectl get kafka my-cluster -n kafka -o yaml > $BACKUP_DIR/kafka-cluster_$DATE.yaml
kubectl get kafkauser -n kafka -o yaml > $BACKUP_DIR/kafka-users_$DATE.yaml

# 메타데이터 백업 (KRaft)
kubectl exec -n kafka my-cluster-kafka-0 -- \
  kafka-metadata-shell.sh --snapshot /tmp/kraft-combined-logs/__cluster_metadata-0/00000000000000000000.log \
  --print > $BACKUP_DIR/metadata_$DATE.txt
```

### 9.2 롤링 업데이트
```bash
# Kafka 버전 업그레이드 (3.9 -> 4.0)
kubectl patch kafka my-cluster -n kafka --type='merge' -p='{"spec":{"kafka":{"version":"4.0.0"}}}'

# 업그레이드 상태 모니터링
kubectl get kafka my-cluster -n kafka -w
kubectl get pods -n kafka -w
```

## 10. 트러블슈팅

### 10.1 일반적인 문제 해결
```bash
# 1. Pod 시작 실패
kubectl describe pod my-cluster-kafka-0 -n kafka
kubectl logs my-cluster-kafka-0 -n kafka --previous

# 2. 스토리지 문제
kubectl get pv
kubectl get pvc -n kafka

# 3. 네트워크 연결 문제
kubectl exec -n kafka my-cluster-kafka-0 -- netstat -tlnp
kubectl exec -n kafka my-cluster-kafka-0 -- kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# 4. 인증 문제
kubectl get secret kafka-admin -n kafka -o yaml
kubectl logs kafka-prod-entity-operator -n kafka -c user-operator
```

### 10.2 성능 튜닝
```bash
# JVM 힙 덤프
kubectl exec -n kafka my-cluster-kafka-0 -- jcmd 1 GC.run_finalization
kubectl exec -n kafka my-cluster-kafka-0 -- jcmd 1 VM.gc

# 메트릭 확인
curl -s localhost:9404/metrics | grep kafka_server
```

이 가이드를 따라하면 온프레미스 환경에서 Kafka 4.0 KRaft 모드를 Strimzi로 안정적으로 구성할 수 있습니다.