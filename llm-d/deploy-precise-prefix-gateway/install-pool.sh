#!/bin/bash
# install-pool.sh — 为一个模型创建完整的推理池
#
# 每个推理池包含：render service + AgentgatewayParameters + Gateway + EPP + HTTPRoute + InferencePool
# 可重复调用，每次为一个不同的模型新增独立的推理池
#
# 用法：
#   bash install-pool.sh --pool qwen25-7b
#   bash install-pool.sh --pool glm4-9b
#   bash install-pool.sh \
#     --guide-name my-pool \
#     --served-model my-model \
#     --render-model-path /path/to/model \
#     --model-cache /root/models \
#     --gateway-node-port 31820 \
#     --namespace llm-d-my-ns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 默认参数 ---
POOL=""
GUIDE_NAME=""
SERVED_MODEL=""
RENDER_MODEL_PATH=""
MODEL_CACHE="/root/models"
NAMESPACE="llm-d-precise-prefix-gw"
GATEWAY_NODE_PORT=""
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-precise-prefix-gateway}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)              POOL="$2";               shift 2 ;;
    --guide-name)        GUIDE_NAME="$2";          shift 2 ;;
    --served-model)      SERVED_MODEL="$2";        shift 2 ;;
    --render-model-path) RENDER_MODEL_PATH="$2";   shift 2 ;;
    --model-cache)       MODEL_CACHE="$2";         shift 2 ;;
    --gateway-node-port) GATEWAY_NODE_PORT="$2";   shift 2 ;;
    --namespace)         NAMESPACE="$2";           shift 2 ;;
    *) shift ;;
  esac
done

# --- 从 pools/<name>/pool.env 读取配置 ---
if [[ -n "$POOL" ]]; then
  POOL_ENV="$SCRIPT_DIR/pools/$POOL/pool.env"
  if [[ -f "$POOL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$POOL_ENV"
    echo "  已加载配置: $POOL_ENV"
  else
    echo "ERROR: pools/$POOL/pool.env 不存在" >&2
    echo "可用的 pool:" >&2
    ls "$SCRIPT_DIR/pools/" 2>/dev/null | sed 's/^/  /' >&2
    exit 1
  fi
fi

# --- 参数校验 ---
: "${GUIDE_NAME:?必须设置 GUIDE_NAME（--guide-name 或 pool.env）}"
: "${SERVED_MODEL:?必须设置 SERVED_MODEL（--served-model 或 pool.env）}"

# --- 自动解析 render 模型路径 ---
if [[ -z "$RENDER_MODEL_PATH" && -n "$MODEL_PATH_RAW" ]]; then
  if [[ -d "${MODEL_PATH_RAW}/snapshots" ]]; then
    RENDER_MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  else
    RENDER_MODEL_PATH="$MODEL_PATH_RAW"
  fi
fi
: "${RENDER_MODEL_PATH:?必须设置 RENDER_MODEL_PATH（--render-model-path 或 pool.env 中的 MODEL_PATH_RAW）}"

ROUTER_CHART_DIR="$DEPLOY_DIR/llm-d-router-gateway"
[ -f "$ROUTER_CHART_DIR/Chart.yaml" ] || { echo "ERROR: $ROUTER_CHART_DIR 不存在，请先运行 prepare.sh" >&2; exit 1; }

echo "=============================================="
echo "  安装推理池: $GUIDE_NAME"
echo "  模型名:     $SERVED_MODEL"
echo "  Render路径: $RENDER_MODEL_PATH"
echo "  Namespace:  $NAMESPACE"
[[ -n "${GATEWAY_NODE_PORT}" ]] && echo "  Gateway端口: $GATEWAY_NODE_PORT" || echo "  Gateway端口: 随机分配"
echo "=============================================="

echo "=== 1. Deploy render (tokenizer) Service ==="
kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${GUIDE_NAME}-render
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: ${GUIDE_NAME}
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/component: vllm-render
      app.kubernetes.io/part-of: ${GUIDE_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/component: vllm-render
        app.kubernetes.io/part-of: ${GUIDE_NAME}
    spec:
      automountServiceAccountToken: false
      containers:
      - name: vllm-render
        image: docker.io/vllm/vllm-openai-cpu:v0.23.0
        imagePullPolicy: IfNotPresent
        command: ["vllm", "launch", "render"]
        args:
        - "${RENDER_MODEL_PATH}"
        - "--port=8000"
        - "--served-model-name=${SERVED_MODEL}"
$([ -n "${TRUST_REMOTE_CODE:-}" ] && printf '        - "%s"\n' "${TRUST_REMOTE_CODE}" || true)
        ports:
        - name: render-http
          containerPort: 8000
        env:
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
          limits:
            cpu: "4"
            memory: 12Gi
        readinessProbe:
          httpGet: {path: /health, port: render-http}
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 30
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE}
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ${GUIDE_NAME}-render
  namespace: ${NAMESPACE}
spec:
  selector:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: ${GUIDE_NAME}
  ports:
  - name: render-http
    port: 8000
    targetPort: render-http
    protocol: TCP
EOF

echo "=== 2. Deploy AgentgatewayParameters + Gateway ==="

# 若指定了固定端口，先创建 AgentgatewayParameters 把 nodePort 写入 Service spec
if [[ -n "${GATEWAY_NODE_PORT}" ]]; then
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: ${GUIDE_NAME}-params
  namespace: ${NAMESPACE}
spec:
  service:
    spec:
      ports:
      - name: http
        port: 80
        targetPort: 80
        nodePort: ${GATEWAY_NODE_PORT}
        protocol: TCP
EOF
  echo "  AgentgatewayParameters: nodePort=${GATEWAY_NODE_PORT}"
fi

# 每个池独立一个 Gateway（独立 NodePort，不互相干扰路由规则）
# 若已创建 AgentgatewayParameters，通过 infrastructure.parametersRef 引用使端口固定
INFRA_BLOCK=""
if [[ -n "${GATEWAY_NODE_PORT}" ]]; then
  INFRA_BLOCK="  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: ${GUIDE_NAME}-params"
fi

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GUIDE_NAME}-gateway
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: agentgateway
${INFRA_BLOCK}
  listeners:
  - port: 80
    protocol: HTTP
    name: default
    allowedRoutes:
      namespaces:
        from: All
EOF
echo "  等待 Gateway programmed..."
kubectl wait "gateway/${GUIDE_NAME}-gateway" -n "${NAMESPACE}" \
  --for=jsonpath='{.status.conditions[?(@.type=="Programmed")].status}=True' \
  --timeout=60s 2>/dev/null || kubectl get "gateway/${GUIDE_NAME}-gateway" -n "${NAMESPACE}"

echo "=== 3. Install EPP + HTTPRoute + InferencePool ==="
helm upgrade --install "${GUIDE_NAME}" "$ROUTER_CHART_DIR" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/recipes/router/features/httproute-flags.yaml" \
  -f "${REPO_ROOT}/guides/precise-prefix-cache-routing/router/precise-prefix-cache-routing.values.yaml" \
  -n "${NAMESPACE}" \
  --set provider.name=agentgateway \
  --set "httpRoute.inferenceGatewayName=${GUIDE_NAME}-gateway" \
  --set "router.epp.pluginsCustomConfig.precise-prefix-cache-routing-plugins\\.yaml=apiVersion: llm-d.ai/v1alpha1
kind: EndpointPickerConfig
plugins:
  - type: token-producer
    parameters:
      modelName: ${SERVED_MODEL}
      vllm:
        url: \"http://${GUIDE_NAME}-render:8000\"
  - type: endpoint-notification-source
  - type: precise-prefix-cache-producer
    parameters:
      tokenProcessorConfig:
        blockSize: 64
      speculativeIndexing: true
      indexerConfig:
        kvBlockIndexConfig:
          enableMetrics: true
      kvEventsConfig:
        topicFilter: \"kv@\"
        engineType: \"vllm\"
        concurrency: 8
        discoverPods: true
        podDiscoveryConfig:
          socketPort: 5556
  - type: prefix-cache-scorer
    parameters:
      prefixMatchInfoProducerName: precise-prefix-cache-producer
  - type: kv-cache-utilization-scorer
  - type: queue-scorer
  - type: no-hit-lru-scorer
    parameters:
      prefixMatchInfoProducerName: precise-prefix-cache-producer
dataLayer:
  sources:
    - pluginRef: endpoint-notification-source
      extractors:
        - pluginRef: precise-prefix-cache-producer
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: kv-cache-utilization-scorer
        weight: 2.0
      - pluginRef: queue-scorer
        weight: 2.0
      - pluginRef: prefix-cache-scorer
        weight: 3.0
      - pluginRef: no-hit-lru-scorer
        weight: 2.0" \
  --wait --timeout=180s

echo ""
echo "=== 推理池 ${GUIDE_NAME} 安装完成 ==="
kubectl get pods,svc -n "${NAMESPACE}" -l "app.kubernetes.io/part-of=${GUIDE_NAME}" 2>/dev/null
kubectl get gateway,httproute,inferencepool -n "${NAMESPACE}" | grep "${GUIDE_NAME}" 2>/dev/null

NODE_PORT=$(kubectl get svc "${GUIDE_NAME}-gateway" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "<pending>")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
echo ""
echo "访问地址: http://${NODE_IP}:${NODE_PORT}"
echo "下一步: 运行 models/ 下的 start-*.sh 部署模型 pod"
