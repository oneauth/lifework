#!/bin/bash

Kubernetes Offline Installation for RHEL 9.4

Run this script in two phases: DOWNLOAD phase on internet-connected system, INSTALL phase on offline system

PHASE=${1:-"DOWNLOAD"}
K8S_VERSION="1.33.0"
CONTAINERD_VERSION="2.1.2"
RUNC_VERSION="1.3.0"
CNI_VERSION="1.6.0"

if [ "$PHASE" = "DOWNLOAD" ]; then
echo "=== DOWNLOAD PHASE: Run on internet-connected system ==="

# Create directories  
mkdir -p k8s-offline/{rpms,images,binaries,configs}  
cd k8s-offline  

# Download Kubernetes repository configuration  
cat > configs/kubernetes.repo << EOF

[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Download GPG key  
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/rpm/repodata/repomd.xml.key > configs/kubernetes-key.gpg  

# Download containerd  
wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz -O binaries/containerd.tar.gz  

# Download runc  
wget https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64 -O binaries/runc  

# Download CNI plugins  
wget https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz -O binaries/cni-plugins.tgz  

# Download crictl  
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v${K8S_VERSION}/crictl-v${K8S_VERSION}-linux-amd64.tar.gz -O binaries/crictl.tar.gz  

# Create temporary repo and download RPMs  
sudo cp configs/kubernetes.repo /etc/yum.repos.d/  
sudo rpm --import configs/kubernetes-key.gpg  
  
# Download Kubernetes RPMs  
sudo dnf download --downloadonly --downloaddir=rpms kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION}  
  
# Download dependencies  
sudo dnf download --downloadonly --downloaddir=rpms --resolve container-selinux iptables iproute-tc socat  
  
# Clean up temporary repo  
sudo rm /etc/yum.repos.d/kubernetes.repo  

# Install containerd temporarily for image download (if not already installed)  
if ! command -v ctr &> /dev/null; then  
    echo "Installing containerd temporarily for image download..."  
    wget https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz -O /tmp/containerd-temp.tar.gz  
    sudo tar -C /usr/local -xzf /tmp/containerd-temp.tar.gz  
      
    # Start containerd temporarily  
    sudo /usr/local/bin/containerd &  
    CONTAINERD_PID=$!  
    sleep 5  
      
    TEMP_CONTAINERD=true  
else  
    TEMP_CONTAINERD=false  
fi  

# Download container images using containerd  
echo "Downloading container images..."  
  
# Get image list from kubeadm or use predefined list  
IMAGES="

registry.k8s.io/kube-apiserver:v${K8S_VERSION}
registry.k8s.io/kube-controller-manager:v${K8S_VERSION}
registry.k8s.io/kube-scheduler:v${K8S_VERSION}
registry.k8s.io/kube-proxy:v${K8S_VERSION}
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.5.16-0
registry.k8s.io/coredns/coredns:v1.12.0
"

# Additional images for networking (Calico example)  
ADDITIONAL_IMAGES="

docker.io/calico/cni:v3.29.1
docker.io/calico/node:v3.29.1
docker.io/calico/kube-controllers:v3.29.1
docker.io/calico/apiserver:v3.29.1
docker.io/calico/typha:v3.29.1
"

ALL_IMAGES="$IMAGES $ADDITIONAL_IMAGES"  

for img in $ALL_IMAGES; do  
    echo "Pulling $img"  
    sudo ctr image pull $img  
    sudo ctr image export images/$(echo $img | tr '/:' '_').tar $img  
    gzip images/$(echo $img | tr '/:' '_').tar  
done  

# Alternative method using skopeo if containerd fails  
cat > download-images-skopeo.sh << 'EOF'

#!/bin/bash

Alternative image download script using skopeo

Install skopeo first: sudo dnf install -y skopeo

IMAGES="
registry.k8s.io/kube-apiserver:v1.33.0
registry.k8s.io/kube-controller-manager:v1.33.0
registry.k8s.io/kube-scheduler:v1.33.0
registry.k8s.io/kube-proxy:v1.33.0
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.5.16-0
registry.k8s.io/coredns/coredns:v1.12.0
docker.io/calico/cni:v3.29.1
docker.io/calico/node:v3.29.1
docker.io/calico/kube-controllers:v3.29.1
docker.io/calico/apiserver:v3.29.1
docker.io/calico/typha:v3.29.1
"

mkdir -p images
for img in $IMAGES; do
echo "Downloading $img with skopeo..."
skopeo copy docker://$img docker-archive:images/$(echo $img | tr '/:' '').tar:$img
gzip images/$(echo $img | tr '/:' '').tar
done
EOF
chmod +x download-images-skopeo.sh

# Cleanup temporary containerd if we started it  
if [ "$TEMP_CONTAINERD" = true ]; then  
    sudo kill $CONTAINERD_PID 2>/dev/null || true  
    sudo rm -f /tmp/containerd-temp.tar.gz  
fi  

# Create installation configs  
cat > configs/containerd-config.toml << 'EOF'

version = 3

[plugins]
[plugins."io.containerd.grpc.v1.cri"]
sandbox_image = "registry.k8s.io/pause:3.10"

[plugins."io.containerd.grpc.v1.cri".containerd]  
  snapshotter = "overlayfs"  
  default_runtime_name = "runc"  
    
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]  
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]  
      runtime_type = "io.containerd.runc.v2"  
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]  
        SystemdCgroup = true  
  
[plugins."io.containerd.grpc.v1.cri".cni]  
  bin_dir = "/opt/cni/bin"  
  conf_dir = "/etc/cni/net.d"  

[plugins."io.containerd.grpc.v1.cri".registry]  
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]  
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]  
      endpoint = ["https://registry-1.docker.io"]  
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]  
      endpoint = ["https://registry.k8s.io"]

[plugins."io.containerd.gc.v1.scheduler"]
pause_threshold = 0.02
deletion_threshold = 0
mutation_threshold = 100
schedule_delay = "0s"
startup_delay = "100ms"
EOF

cat > configs/kubelet-config.yaml << 'EOF'

apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
EOF

cat > configs/kubeadm-config.yaml << EOF

apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
advertiseAddress: "10.10.10.99"
bindPort: 6443
nodeRegistration:
criSocket: unix:///run/containerd/containerd.sock
kubeletExtraArgs:
cgroup-driver: systemd

apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
clusterName: "kubernetes"
controlPlaneEndpoint: "10.10.10.99:6443"
apiServer:
advertiseAddress: "10.10.10.99"
bindPort: 6443
networking:
serviceSubnet: "10.96.0.0/12"
podSubnet: "192.168.0.0/16"
dnsDomain: "cluster.local"
etcd:
local:
dataDir: "/var/lib/etcd"
dns:
type: CoreDNS

apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
bootstrapToken:
apiServerEndpoint: "10.10.10.99:6443"
token: "REPLACE_WITH_TOKEN"
caCertHashes:
- "REPLACE_WITH_CA_HASH"
nodeRegistration:
criSocket: unix:///run/containerd/containerd.sock
kubeletExtraArgs:
cgroup-driver: systemd

apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
rotateCertificates: true
EOF

# Create Calico manifest with custom pod CIDR  
wget https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml -O configs/calico.yaml  
  
# Create cluster setup script for master node  
cat > configs/setup-master.sh << 'EOF'

#!/bin/bash
echo "=== Initializing Kubernetes Master Node ==="

Initialize the cluster

echo "Initializing cluster..."
sudo kubeadm init --config=kubeadm-config.yaml

if [ $? -eq 0 ]; then
echo "Cluster initialized successfully!"

# Setup kubectl for current user  
echo "Setting up kubectl..."  
mkdir -p $HOME/.kube  
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config  
sudo chown $(id -u):$(id -g) $HOME/.kube/config  
  
# Wait for nodes to be ready  
echo "Waiting for node to be ready..."  
kubectl wait --for=condition=Ready node --all --timeout=300s  
  
# Apply Calico network  
echo "Applying Calico network plugin..."  
kubectl apply -f calico.yaml  
  
# Generate join command for worker nodes  
echo "Generating join commands for worker nodes..."  
echo "#!/bin/bash" > join-workers.sh  
echo "# Run this script on worker nodes to join the cluster" >> join-workers.sh  
echo "" >> join-workers.sh  
  
JOIN_CMD=$(kubeadm token create --print-join-command)  
echo "$JOIN_CMD --cri-socket unix:///run/containerd/containerd.sock" >> join-workers.sh  
  
chmod +x join-workers.sh  
  
echo ""  
echo "=== Master node setup complete! ==="  
echo ""  
echo "Worker nodes (10.10.10.100, 10.10.10.103, 10.10.10.105):"  
echo "1. Copy the k8s-offline directory to each worker node"  
echo "2. Run: ./install-k8s-offline.sh INSTALL"  
echo "3. Copy and run the join-workers.sh script"  
echo ""  
echo "Join command for worker nodes:"  
cat join-workers.sh

else
echo "Failed to initialize cluster. Please check the logs."
exit 1
fi
EOF
chmod +x configs/setup-master.sh

# Create worker node setup script  
cat > configs/setup-worker.sh << 'EOF'

#!/bin/bash
MASTER_IP="10.10.10.99"
NODE_IP=$(hostname -I | awk '{print $1}')

echo "=== Setting up Kubernetes Worker Node ==="
echo "Node IP: $NODE_IP"
echo "Master IP: $MASTER_IP"

Check if join command file exists

if [ ! -f "join-workers.sh" ]; then
echo "Error: join-workers.sh not found!"
echo "Please copy the join-workers.sh file from the master node."
exit 1
fi

Make sure the join script is executable

chmod +x join-workers.sh

Execute the join command

echo "Joining the cluster..."
sudo ./join-workers.sh

if [ $? -eq 0 ]; then
echo ""
echo "=== Worker node successfully joined the cluster! ==="
echo "Node IP: $NODE_IP"
echo ""
echo "To verify from master node, run:"
echo "kubectl get nodes -o wide"
else
echo "Failed to join the cluster. Please check:"
echo "1. Network connectivity to master node ($MASTER_IP:6443)"
echo "2. Firewall settings"
echo "3. join-workers.sh script content"
exit 1
fi
EOF
chmod +x configs/setup-worker.sh

echo "Download complete. Transfer the 'k8s-offline' directory to your offline system."  
echo ""  
echo "📦 Downloaded packages:"  
echo "  - Kubernetes RPMs: $(ls rpms/*.rpm 2>/dev/null | wc -l) files"  
echo "  - Container images: $(ls images/*.tar.gz 2>/dev/null | wc -l) files"  
echo "  - Binaries: containerd, runc, CNI plugins, crictl"  
echo ""  
echo "🔧 If image download failed, you can also:"  
echo "  1. Install skopeo: sudo dnf install -y skopeo"  
echo "  2. Run: ./download-images-skopeo.sh"  
echo ""  
echo "Then run: $0 INSTALL"

elif [ "$PHASE" = "INSTALL" ]; then
echo "=== INSTALL PHASE: Run on offline RHEL 9.4 system ==="

if [ ! -d "k8s-offline" ]; then  
    echo "Error: k8s-offline directory not found. Make sure you've transferred the files from the download phase."  
    exit 1  
fi  
  
cd k8s-offline  
  
# System preparation  
echo "Preparing system..."  
  
# Disable swap  
sudo swapoff -a  
sudo sed -i '/ swap / s/^/#/' /etc/fstab  
  
# Configure kernel modules  
cat > /tmp/k8s-modules.conf << EOF

overlay
br_netfilter
EOF
sudo cp /tmp/k8s-modules.conf /etc/modules-load.d/k8s.conf
sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl  
cat > /tmp/k8s-sysctl.conf << EOF

net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo cp /tmp/k8s-sysctl.conf /etc/sysctl.d/k8s.conf
sudo sysctl --system

# Install RPMs  
echo "Installing RPMs..."  
sudo dnf install -y rpms/*.rpm  
  
# Install containerd  
echo "Installing containerd..."  
sudo tar -C /usr/local -xzf binaries/containerd.tar.gz  
  
# Install runc  
sudo install -m 755 binaries/runc /usr/local/sbin/runc  
  
# Install CNI plugins  
sudo mkdir -p /opt/cni/bin  
sudo tar -C /opt/cni/bin -xzf binaries/cni-plugins.tgz  
  
# Install crictl  
sudo tar -C /usr/local/bin -xzf binaries/crictl.tar.gz  
  
# Configure containerd  
sudo mkdir -p /etc/containerd  
sudo cp configs/containerd-config.toml /etc/containerd/config.toml  
  
# Create containerd service  
cat > /tmp/containerd.service << 'EOF'

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
sudo cp /tmp/containerd.service /etc/systemd/system/

# Load container images  
echo "Loading container images..."  
for img_file in images/*.tar.gz; do  
    if [ -f "$img_file" ]; then  
        echo "Loading $(basename $img_file)"  
        gunzip -c "$img_file" | sudo ctr -n k8s.io images import -  
    fi  
done  
  
# Start and enable services  
sudo systemctl daemon-reload  
sudo systemctl enable --now containerd  
sudo systemctl enable --now kubelet  
  
# Configure firewall (if running)  
if systemctl is-active --quiet firewalld; then  
    echo "Configuring firewall..."  
    sudo firewall-cmd --permanent --add-port=6443/tcp  
    sudo firewall-cmd --permanent --add-port=2379-2380/tcp  
    sudo firewall-cmd --permanent --add-port=10250/tcp  
    sudo firewall-cmd --permanent --add-port=10259/tcp  
    sudo firewall-cmd --permanent --add-port=10257/tcp  
    sudo firewall-cmd --permanent --add-port=179/tcp  
    sudo firewall-cmd --permanent --add-masquerade  
    sudo firewall-cmd --reload  
fi  
  
echo "Installation complete!"  
echo ""  
echo "=== Next Steps ==="  
echo ""  
if [ "$(hostname -I | awk '{print $1}')" = "10.10.10.99" ]; then  
    echo "🎯 MASTER NODE (10.10.10.99) - Run this:"  
    echo "   cd k8s-offline/configs"  
    echo "   ./setup-master.sh"  
    echo ""  
else  
    echo "🔧 WORKER NODE - After master is ready, run this:"  
    echo "   cd k8s-offline/configs"  
    echo "   # Copy join-workers.sh from master node first"  
    echo "   ./setup-worker.sh"  
    echo ""  
fi  
echo "📋 Node Information:"  
echo "   - Master:  10.10.10.99"  
echo "   - Worker1: 10.10.10.100"  
echo "   - Worker2: 10.10.10.103"  
echo "   - Worker3: 10.10.10.105"  
echo ""  
echo "🔥 Firewall ports opened: 6443, 2379-2380, 10250, 10259, 10257, 179"

else
echo "Usage: $0 [DOWNLOAD|INSTALL]"
echo "DOWNLOAD: Run on internet-connected system to download packages"
echo "INSTALL: Run on offline RHEL 9.4 system to install Kubernetes"
fi

