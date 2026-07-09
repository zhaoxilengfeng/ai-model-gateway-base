REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"

declare -A images=(
  ["aibrix-controller-manager:v0.7.0"]="aibrix/controller-manager:v0.7.0"
  ["aibrix-gateway-plugins:v0.7.0"]="aibrix/gateway-plugins:v0.7.0"
  ["aibrix-runtime:v0.7.0"]="aibrix/runtime:v0.7.0"
  ["aibrix-metadata-service:v0.7.0"]="aibrix/metadata-service:v0.7.0"
  ["busybox:stable"]="busybox:stable"
  ["redis:7.4"]="redis:7.4"
  ["envoyproxy-envoy:v1.33.2"]="envoyproxy/envoy:v1.33.2"
  ["envoyproxy-gateway:v1.2.8"]="envoyproxy/gateway:v1.2.8"
  ["vllm-openai:v0.6.6.post1"]="vllm/vllm-openai:v0.6.6.post1"
)

for cached in "${!images[@]}"; do
  original="${images[$cached]}"
  docker pull "$REGISTRY/$cached"
  docker tag "$REGISTRY/$cached" "$original"
done
