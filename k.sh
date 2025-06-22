#!/bin/bash
# Kubernetes (K8s) and K3s Cluster Switcher
# Allows running both K8s and K3s on same VMs with instant switching

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/cluster-config.yaml"
CURRENT_STATE_FILE="$SCRIPT_DIR/.current-cluster"

# Cluster configuration
K8S_MASTER="10.10.10.99"
K8S_WORKERS=("10.10.10.100" "10.10.10.103" "10.10.10.105")
K3S_MASTER="10.10.10.99"
K3S_WORKERS=("10.10.10.100" "10.10.10.103" "10.10.10.105")

# Port configurations to avoid conflicts
K8S_API_PORT="6443"
K3S_API_PORT="6444"
K8S_ETCD_PORTS="2379-2380"
K3S_ETCD_PORTS="2381-2382"

function print_usage() {
    cat << EOF
🚀 Kubernetes & K3s Cluster Switcher

Usage: $0 [COMMAND]

Commands:
  setup           - Install both K8s and K3s (offline packages required)
  switch k8s      - Activate K8s cluster, deactivate K3s
  switch k3s      - Activate K3s cluster, deactivate K8s
  status          - Show current active cluster and service status
  both-active     - Run both clusters simultaneously (advanced)
  stop-all        - Stop both clusters
  kubeconfig k8s  - Set kubectl to use K8s cluster
  kubeconfig k3s  - Set kubectl to use K3s cluster
  health-check    - Check health of both clusters
  reset           - Reset both clusters (WARNING: destroys data)

Examples:
  $0 setup                    # Initial setup
  $0 switch k8s              # Switch to K8s
  $0 switch k3s              # Switch to K3s
  $0 kubeconfig k8s          # Point kubectl to K8s
  $0 status                  # Check status

Current State: $(get_current_state)
EOF
}

function get_current_state() {
    if [ -f "$CURRENT_STATE_FILE" ]; then
        cat "$CURRENT_STATE_FILE"
    else
        echo "unknown"
    fi
}

function set_current_state() {
    echo "$1" > "$CURRENT_STATE_FILE"
}

function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

function check_node_type() {
    local current_ip=$(hostname -I | awk '{print $1}')
    if [ "$current_ip" = "$K8S_MASTER" ]; then
        echo "master"
    else
        echo "worker"
    fi
}

function setup_k8s_config() {
    log "Setting up K8s configuration..."
    
    # Create K8s specific containerd config
    sudo mkdir -p /etc/containerd-k8s
    cat > /tmp/containerd-k8s.toml << 'EOF'
version = 3

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"
  
[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  default_runtime_name = "runc"
  
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"
EOF
    sudo cp /tmp/containerd-k8s.toml /etc/containerd-k8s/config.toml

    # Create K8s kubeadm config with custom API port
    cat > /tmp/kubeadm-k8s.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$K8S_MASTER"
  bindPort: $K8S_API_PORT
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.33.0
clusterName: "k8s-cluster"
controlPlaneEndpoint: "$K8S_MASTER:$K8S_API_PORT"
apiServer:
  advertiseAddress: "$K8S_MASTER"
  bindPort: $K8S_API_PORT
networking:
  serviceSubnet: "10.96.0.0/12"
  podSubnet: "192.168.0.0/16"
  dnsDomain: "cluster.local"
etcd:
  local:
    dataDir: "/var/lib/etcd-k8s"
    serverCertSANs:
    - "$K8S_MASTER"
    peerCertSANs:
    - "$K8S_MASTER"
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://$K8S_MASTER:2379"
      advertise-client-urls: "https://$K8S_MASTER:2379"
      listen-peer-urls: "https://$K8S_MASTER:2380"
      initial-advertise-peer-urls: "https://$K8S_MASTER:2380"
EOF
    sudo cp /tmp/kubeadm-k8s.yaml /etc/kubernetes/kubeadm-k8s.yaml
}

function setup_k3s_config() {
    log "Setting up K3s configuration..."
    
    # Create K3s config directory
    sudo mkdir -p /etc/rancher/k3s
    
    # K3s server config
    cat > /tmp/k3s-config.yaml << EOF
cluster-init: true
token: "k3s-cluster-secret-token"
data-dir: "/var/lib/rancher/k3s-data"
https-listen-port: $K3S_API_PORT
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
flannel-backend: "vxlan"
disable:
  - traefik
  - metrics-server
write-kubeconfig: "/etc/rancher/k3s/k3s.yaml"
write-kubeconfig-mode: "644"
EOF
    sudo cp /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml
}

function install_k3s() {
    log "Installing K3s..."
    
    # Download K3s binary
    if [ ! -f "/usr/local/bin/k3s" ]; then
        curl -L https://github.com/k3s-io/k3s/releases/latest/download/k3s -o /tmp/k3s
        sudo cp /tmp/k3s /usr/local/bin/k3s
        sudo chmod +x /usr/local/bin/k3s
    fi
    
    # Create K3s systemd service
    cat > /tmp/k3s.service << 'EOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/etc/systemd/system/k3s.service.env
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service 2>/dev/null'
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server --config /etc/rancher/k3s/config.yaml
EOF
    
    sudo cp /tmp/k3s.service /etc/systemd/system/k3s.service
    sudo systemctl daemon-reload
}

function setup_kubectl_configs() {
    log "Setting up kubectl configurations..."
    
    # Create kubectl config directories
    mkdir -p ~/.kube/configs
    
    # Create kubeconfig switcher script
    cat > ~/.kube/switch-context.sh << 'EOF'
#!/bin/bash
case "$1" in
    k8s)
        export KUBECONFIG=~/.kube/configs/k8s-config
        echo "Switched to K8s cluster"
        ;;
    k3s)
        export KUBECONFIG=~/.kube/configs/k3s-config
        echo "Switched to K3s cluster"
        ;;
    *)
        echo "Usage: source switch-context.sh [k8s|k3s]"
        ;;
esac
EOF
    chmod +x ~/.kube/switch-context.sh
    
    # Create aliases for easy switching
    cat >> ~/.bashrc << 'EOF'

# K8s/K3s Cluster Switcher Aliases
alias k8s-cluster='export KUBECONFIG=~/.kube/configs/k8s-config && echo "✅ Switched to K8s cluster"'
alias k3s-cluster='export KUBECONFIG=~/.kube/configs/k3s-config && echo "✅ Switched to K3s cluster"'
alias cluster-status='kubectl cluster-info 2>/dev/null || echo "❌ No active cluster"'
alias k8s-status='KUBECONFIG=~/.kube/configs/k8s-config kubectl get nodes 2>/dev/null || echo "❌ K8s not running"'
alias k3s-status='KUBECONFIG=~/.kube/configs/k3s-config kubectl get nodes 2>/dev/null || echo "❌ K3s not running"'
EOF
}

function setup_firewall_rules() {
    log "Setting up firewall rules for both clusters..."
    
    if systemctl is-active --quiet firewalld; then
        # K8s ports
        sudo firewall-cmd --permanent --add-port=$K8S_API_PORT/tcp
        sudo firewall-cmd --permanent --add-port=$K8S_ETCD_PORTS/tcp
        
        # K3s ports
        sudo firewall-cmd --permanent --add-port=$K3S_API_PORT/tcp
        sudo firewall-cmd --permanent --add-port=8472/udp  # Flannel VXLAN
        
        # Common ports
        sudo firewall-cmd --permanent --add-port=10250/tcp
        sudo firewall-cmd --permanent --add-port=179/tcp
        sudo firewall-cmd --permanent --add-masquerade
        
        sudo firewall-cmd --reload
    fi
}

function start_k8s_cluster() {
    log "Starting K8s cluster..."
    
    # Copy K8s containerd config
    sudo cp /etc/containerd-k8s/config.toml /etc/containerd/config.toml
    
    # Restart containerd with K8s config
    sudo systemctl restart containerd
    
    # Start kubelet
    sudo systemctl start kubelet
    
    local node_type=$(check_node_type)
    if [ "$node_type" = "master" ]; then
        # Initialize K8s cluster if not already done
        if [ ! -f "/etc/kubernetes/admin.conf" ]; then
            sudo kubeadm init --config=/etc/kubernetes/kubeadm-k8s.yaml
            mkdir -p ~/.kube/configs
            sudo cp /etc/kubernetes/admin.conf ~/.kube/configs/k8s-config
            sudo chown $(id -u):$(id -g) ~/.kube/configs/k8s-config
        fi
        
        # Apply Calico if needed
        if ! KUBECONFIG=~/.kube/configs/k8s-config kubectl get pods -n kube-system | grep -q calico; then
            KUBECONFIG=~/.kube/configs/k8s-config kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml
        fi
    fi
    
    set_current_state "k8s"
}

function start_k3s_cluster() {
    log "Starting K3s cluster..."
    
    # Stop K8s services
    sudo systemctl stop kubelet 2>/dev/null || true
    
    # Start K3s
    sudo systemctl start k3s
    
    # Copy K3s kubeconfig
    if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
        mkdir -p ~/.kube/configs
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/configs/k3s-config
        sudo chown $(id -u):$(id -g) ~/.kube/configs/k3s-config
        
        # Update server URL to use custom port
        sed -i "s|https://127.0.0.1:6443|https://$K3S_MASTER:$K3S_API_PORT|g" ~/.kube/configs/k3s-config
    fi
    
    set_current_state "k3s"
}

function stop_k8s_cluster() {
    log "Stopping K8s cluster..."
    sudo systemctl stop kubelet 2>/dev/null || true
}

function stop_k3s_cluster() {
    log "Stopping K3s cluster..."
    sudo systemctl stop k3s 2>/dev/null || true
}

function setup_both_clusters() {
    log "Setting up both K8s and K3s clusters..."
    
    # Verify offline packages exist
    if [ ! -d "k8s-offline" ]; then
        echo "❌ k8s-offline directory not found. Please run K8s download first."
        exit 1
    fi
    
    # Install K8s first
    log "Installing K8s components..."
    cd k8s-offline && ./install-k8s-offline.sh INSTALL && cd ..
    
    # Setup K8s configurations
    setup_k8s_config
    
    # Install and setup K3s
    install_k3s
    setup_k3s_config
    
    # Setup kubectl configurations
    setup_kubectl_configs
    
    # Setup firewall
    setup_firewall_rules
    
    log "✅ Both clusters setup complete!"
    log "Use '$0 switch k8s' or '$0 switch k3s' to activate clusters"
}

function switch_cluster() {
    local target="$1"
    
    case "$target" in
        k8s)
            stop_k3s_cluster
            start_k8s_cluster
            export KUBECONFIG=~/.kube/configs/k8s-config
            log "✅ Switched to K8s cluster"
            ;;
        k3s)
            stop_k8s_cluster
            start_k3s_cluster
            export KUBECONFIG=~/.kube/configs/k3s-config
            log "✅ Switched to K3s cluster"
            ;;
        *)
            echo "❌ Invalid cluster. Use 'k8s' or 'k3s'"
            exit 1
            ;;
    esac
}

function show_status() {
    echo "🔍 Cluster Status Report"
    echo "======================="
    
    local current=$(get_current_state)
    echo "Current Active: $current"
    echo ""
    
    # Check K8s status
    echo "📊 K8s Cluster:"
    if sudo systemctl is-active --quiet kubelet; then
        echo "  Status: 🟢 Active"
        if [ -f ~/.kube/configs/k8s-config ]; then
            KUBECONFIG=~/.kube/configs/k8s-config kubectl get nodes 2>/dev/null | head -1
            KUBECONFIG=~/.kube/configs/k8s-config kubectl get nodes 2>/dev/null | grep -v NAME | wc -l | xargs echo "  Nodes:"
        fi
    else
        echo "  Status: 🔴 Inactive"
    fi
    
    echo ""
    
    # Check K3s status
    echo "📊 K3s Cluster:"
    if sudo systemctl is-active --quiet k3s; then
        echo "  Status: 🟢 Active"
        if [ -f ~/.kube/configs/k3s-config ]; then
            KUBECONFIG=~/.kube/configs/k3s-config kubectl get nodes 2>/dev/null | head -1
            KUBECONFIG=~/.kube/configs/k3s-config kubectl get nodes 2>/dev/null | grep -v NAME | wc -l | xargs echo "  Nodes:"
        fi
    else
        echo "  Status: 🔴 Inactive"
    fi
    
    echo ""
    echo "💡 Quick Commands:"
    echo "  k8s-cluster     # Switch kubectl to K8s"
    echo "  k3s-cluster     # Switch kubectl to K3s"
    echo "  cluster-status  # Show current kubectl cluster"
}

function set_kubeconfig() {
    local cluster="$1"
    
    case "$cluster" in
        k8s)
            export KUBECONFIG=~/.kube/configs/k8s-config
            echo "export KUBECONFIG=~/.kube/configs/k8s-config" > ~/.kube/current-context
            echo "✅ kubectl now points to K8s cluster"
            ;;
        k3s)
            export KUBECONFIG=~/.kube/configs/k3s-config
            echo "export KUBECONFIG=~/.kube/configs/k3s-config" > ~/.kube/current-context
            echo "✅ kubectl now points to K3s cluster"
            ;;
        *)
            echo "❌ Invalid cluster. Use 'k8s' or 'k3s'"
            exit 1
            ;;
    esac
}

function health_check() {
    echo "🏥 Health Check Report"
    echo "====================="
    
    # Check K8s health
    echo "🔍 K8s Cluster Health:"
    if [ -f ~/.kube/configs/k8s-config ]; then
        KUBECONFIG=~/.kube/configs/k8s-config kubectl get nodes 2>/dev/null || echo "  ❌ K8s cluster not accessible"
        KUBECONFIG=~/.kube/configs/k8s-config kubectl get pods -n kube-system | grep -E "(Running|Ready)" | wc -l | xargs echo "  Running pods:"
    else
        echo "  ❌ K8s config not found"
    fi
    
    echo ""
    
    # Check K3s health
    echo "🔍 K3s Cluster Health:"
    if [ -f ~/.kube/configs/k3s-config ]; then
        KUBECONFIG=~/.kube/configs/k3s-config kubectl get nodes 2>/dev/null || echo "  ❌ K3s cluster not accessible"
        KUBECONFIG=~/.kube/configs/k3s-config kubectl get pods -n kube-system | grep -E "(Running|Ready)" | wc -l | xargs echo "  Running pods:"
    else
        echo "  ❌ K3s config not found"
    fi
}

function run_both_active() {
    log "⚠️  Starting both clusters simultaneously (advanced mode)..."
    start_k8s_cluster
    start_k3s_cluster
    set_current_state "both"
    log "✅ Both clusters are now active"
    log "Use 'kubeconfig k8s' or 'kubeconfig k3s' to switch kubectl context"
}

function stop_all() {
    log "Stopping all clusters..."
    stop_k8s_cluster
    stop_k3s_cluster
    set_current_state "stopped"
    log "✅ All clusters stopped"
}

function reset_clusters() {
    read -p "⚠️  This will destroy all cluster data. Continue? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        log "Resetting both clusters..."
        
        # Reset K8s
        sudo kubeadm reset -f 2>/dev/null || true
        sudo rm -rf /etc/kubernetes/ ~/.kube/configs/k8s-config /var/lib/etcd-k8s
        
        # Reset K3s
        sudo systemctl stop k3s 2>/dev/null || true
        sudo rm -rf /var/lib/rancher/k3s-data ~/.kube/configs/k3s-config
        
        set_current_state "reset"
        log "✅ Both clusters reset"
    else
        log "Reset cancelled"
    fi
}

# Main script logic
case "${1:-help}" in
    setup)
        setup_both_clusters
        ;;
    switch)
        switch_cluster "$2"
        ;;
    status)
        show_status
        ;;
    kubeconfig)
        set_kubeconfig "$2"
        ;;
    health-check)
        health_check
        ;;
    both-active)
        run_both_active
        ;;
    stop-all)
        stop_all
        ;;
    reset)
        reset_clusters
        ;;
    help|*)
        print_usage
        ;;
esac