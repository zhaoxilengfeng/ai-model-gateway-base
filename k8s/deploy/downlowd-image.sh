REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"

declare -A images=(
  # K8s 控制平面
  ["k8s-kube-apiserver:v1.35.0"]="registry.k8s.io/kube-apiserver:v1.35.0"
  ["k8s-kube-controller-manager:v1.35.0"]="registry.k8s.io/kube-controller-manager:v1.35.0"
  ["k8s-kube-scheduler:v1.35.0"]="registry.k8s.io/kube-scheduler:v1.35.0"
  ["k8s-kube-proxy:v1.35.0"]="registry.k8s.io/kube-proxy:v1.35.0"
  ["k8s-etcd:3.6.6-0"]="registry.k8s.io/etcd:3.6.6-0"
  ["k8s-coredns:v1.13.1"]="registry.k8s.io/coredns/coredns:v1.13.1"
  ["k8s-pause:3.10.1"]="registry.k8s.io/pause:3.10.1"
  # Calico v3.32.1
  ["calico-node:v3.32.1"]="quay.io/calico/node:v3.32.1"
  ["calico-cni:v3.32.1"]="quay.io/calico/cni:v3.32.1"
  ["calico-kube-controllers:v3.32.1"]="quay.io/calico/kube-controllers:v3.32.1"
)

for cached in "${!images[@]}"; do
  original="${images[$cached]}"
  ctr image pull "$REGISTRY/$cached"
  ctr image tag "$REGISTRY/$cached" "$original"
done
