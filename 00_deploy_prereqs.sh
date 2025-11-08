#!/bin/bash
set -e

echo "=== [1/7] Disabling swap (Kubernetes requirement) ==="
sudo swapoff -a
sudo sed -ri 's/^[^#]*swap/#&/' /etc/fstab

echo "=== [2/7] Enabling kernel modules for Kubernetes networking ==="
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo "=== [3/7] Applying sysctl settings for Kubernetes networking ==="
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.ip_nonlocal_bind           = 1

EOF

sudo sysctl --system

echo "=== [4/7] Configuring firewall (UFW) for Kubernetes communication ==="
# Example minimal openings (adjust to your security policy)
sudo ufw allow 6443/tcp   # Kubernetes API Server
sudo ufw allow 10250/tcp  # Kubelet API
sudo ufw allow 4789/udp   # VXLAN (Calico, Flannel, etc.)
sudo ufw allow 179/tcp    # BGP (Calico)

echo "✅ Firewall rules added (showing relevant lines):"
sudo ufw status | grep -E "6443|10250|4789|179" || true

echo "=== [5/7] Installing and configuring containerd runtime ==="
sudo apt-get update -y
sudo apt-get install -y containerd

# Generate default config and enable systemd cgroups
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Flip SystemdCgroup = true
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl enable --now containerd

echo "=== [6/7] Adding Kubernetes apt repository (v1.34) ==="
# Prereqs
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Ensure keyring dir exists
sudo mkdir -p /etc/apt/keyrings

# Add the Kubernetes apt repo key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the repo
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "=== [7/7] Installing Kubernetes components (kubeadm, kubelet, kubectl) ==="
sudo apt-get update -y
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl

# Enable kubelet now; kubeadm will later configure it fully
sudo systemctl enable --now kubelet

echo ""
echo "✅ Kubernetes node prerequisites completed successfully!"
echo "now run the second script 01_update_files.sh to setup load balancing of the API server."
