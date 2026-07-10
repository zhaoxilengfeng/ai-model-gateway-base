#!/bin/bash
# deploy-model.sh — 在 llm-d 上部署一个模型
#
# Usage: bash deploy-model.sh [model-name] [model-path] [replicas] [node]
#
# 参数说明：
#   model-name   K8s 资源名（字母数字+连字符），同时作为 served-model-name
#   model-path   模型路径（本地绝对路径 /root/models/... 或 HF repo ID）
#   replicas     副本数，默认 1
#   node         固定调度到某节点（可选），不填则自动调度
#
# 示例：
#   bash deploy-model.sh                                                          # 默认 Qwen2.5-7B
#   bash deploy-model.sh qwen25-7b-instruct /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct 2
#   bash deploy-model.sh qwen25-7b-instruct Qwen/Qwen2.5-7B-Instruct 1 host-000-002
#
# 环境变量（可覆盖）：
#   NAMESPACE           K8s namespace，默认 default
#   EPP_IMAGE           EPP 镜像
#   VLLM_IMAGE          vLLM 镜像
#   MAX_MODEL_LEN       vLLM max-model-len，默认 8192
#   GPU_MEMORY_UTIL     vLLM gpu-memory-utilization，默认 0.85
#   GATEWAY_NAME        Gateway 资源名，默认 inference-gateway
#   GATEWAY_CLASS       GatewayClass，默认 kgateway
#   MODEL_CACHE_PATH    hostPath 挂载路径，默认 /root/models
set -e

# 默认模型：Qwen2.5-7B-Instruct
# model-path 支持三种格式：
#   1. 本地目录   /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct  （自动取最新 snapshot）
#   2. HF repo ID Qwen/Qwen2.5-7B-Instruct                            （走在线下载）
#   3. 完整路径   /root/models/hub/.../snapshots/<hash>
MODEL_NAME="${1:-qwen25-7b-instruct}"
MODEL_PATH_RAW="${2:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"
REPLICAS="${3:-1}"
NODE="${4:-}"

# 如果传入的是 HF cache 模型目录（含 snapshots 子目录），自动取最新 snapshot
if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
  MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/  2>/dev/null | head -1 | sed 's|/$||')
  if [ -z "$MODEL_PATH" ]; then
    echo "ERROR: ${MODEL_PATH_RAW}/snapshots/ 下没有找到 snapshot" >&2
    exit 1
  fi
  echo "  Auto-resolved snapshot: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_PATH_RAW"
fi

NAMESPACE="${NAMESPACE:-default}"
EPP_IMAGE="${EPP_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.85}"
GATEWAY_NAME="${GATEWAY_NAME:-inference-gateway}"
GATEWAY_CLASS="${GATEWAY_CLASS:-kgateway}"
MODEL_CACHE_PATH="${MODEL_CACHE_PATH:-/root/models}"

echo "=== Deploying model: $MODEL_NAME ==="
echo "  Model path: $MODEL_PATH"
echo "  Replicas:   $REPLICAS"
echo "  Node:       ${NODE:-auto}"
echo "  Namespace:  $NAMESPACE"

# nodeSelector block（指定节点时插入）
NODE_SELECTOR_BLOCK=""
if [ -n "$NODE" ]; then
  NODE_SELECTOR_BLOCK="
      nodeSelector:
        kubernetes.io/hostname: ${NODE}"
fi

# model-path 判断：如果是绝对路径用 HF_HUB_OFFLINE=1，否则走在线下载
if [[ "$MODEL_PATH" == /* ]]; then
  HF_ENV='
            - name: HF_HUB_OFFLINE
              value: "1"
            - name: TRANSFORMERS_OFFLINE
              value: "1"'
else
  HF_ENV='
            - name: HF_ENDPOINT
              value: "https://hf-mirror.com"
            - name: HF_HOME
              value: "/models"'
fi

echo "=== 1. Create EPP ConfigMap ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${MODEL_NAME}-epp-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
data:
  config.yaml: |
    plugins:
    - type: single-profile-handler
    - type: decode-filter
    - type: weighted-random-picker
    - type: metrics-data-source
    - type: core-metrics-extractor
      parameters:
        defaultEngine: vllm
        engineConfigs:
        - name: vllm
          queuedRequestsSpec: "vllm:num_requests_waiting"
          runningRequestsSpec: "vllm:num_requests_running"
          kvUsageSpec: "vllm:gpu_cache_usage_perc"
          cacheInfoSpec: "vllm:cache_config_info"
    schedulingProfiles:
    - name: default
      plugins:
      - pluginRef: decode-filter
EOF

echo "=== 2. Create EPP Service ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${MODEL_NAME}-endpoint-picker
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
spec:
  selector:
    app: ${MODEL_NAME}-endpoint-picker
  ports:
  - name: grpc-ext-proc
    port: 9002
    targetPort: 9002
    protocol: TCP
  - name: grpc-health
    port: 9003
    targetPort: 9003
    protocol: TCP
  - name: http-metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
EOF

echo "=== 3. Create EPP Deployment ==="
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}-endpoint-picker
  namespace: ${NAMESPACE}
  labels:
    app: ${MODEL_NAME}-endpoint-picker
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${MODEL_NAME}-endpoint-picker
  template:
    metadata:
      labels:
        app: ${MODEL_NAME}-endpoint-picker
    spec:
      serviceAccountName: llm-d-epp
      terminationGracePeriodSeconds: 30
      containers:
      - name: epp
        image: ${EPP_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - --pool-name=${MODEL_NAME}
        - --pool-namespace=${NAMESPACE}
        - --pool-group=inference.networking.k8s.io
        - --config-file=/config/config.yaml
        - --secure-serving=false
        - --tracing=false
        - --ha-enable-leader-election
        - --v=5
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: OTEL_SDK_DISABLED
          value: "true"
        - name: CONFIG_FILE
          value: /config/config.yaml
        ports:
        - name: grpc
          containerPort: 9002
          protocol: TCP
        - name: grpc-health
          containerPort: 9003
          protocol: TCP
        - name: metrics
          containerPort: 9090
          protocol: TCP
        readinessProbe:
          grpc:
            port: 9003
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          grpc:
            port: 9003
          initialDelaySeconds: 15
          periodSeconds: 20
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 1Gi
        volumeMounts:
        - name: config-volume
          mountPath: /config
      volumes:
      - name: config-volume
        configMap:
          name: ${MODEL_NAME}-epp-config
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${MODEL_NAME}-endpoint-picker-pdb
  namespace: ${NAMESPACE}
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: ${MODEL_NAME}-endpoint-picker
EOF

echo "=== 4. Create InferencePool ==="
kubectl apply -f - <<EOF
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api-inference-extension"
  labels:
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
spec:
  appProtocol: http
  endpointPickerRef:
    failureMode: FailClose
    group: ""
    kind: Service
    name: ${MODEL_NAME}-endpoint-picker
    port:
      number: 9002
  selector:
    matchLabels:
      app: ${MODEL_NAME}
  targetPorts:
  - number: 8000
EOF

echo "=== 5. Create Gateway + HTTPRoute ==="
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: llm-d
spec:
  gatewayClassName: ${GATEWAY_CLASS}
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${MODEL_NAME}-route
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: ${MODEL_NAME}
      port: 8000
EOF

echo "=== 6. Create vLLM Deployment ==="
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${MODEL_NAME}
    app.kubernetes.io/part-of: llm-d
    model: ${MODEL_NAME}
spec:
  replicas: ${REPLICAS}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  selector:
    matchLabels:
      app: ${MODEL_NAME}
  template:
    metadata:
      labels:
        app: ${MODEL_NAME}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      terminationGracePeriodSeconds: 120${NODE_SELECTOR_BLOCK}
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 50
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: ${MODEL_NAME}
              topologyKey: kubernetes.io/hostname
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: vllm
        image: ${VLLM_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
        - --model=${MODEL_PATH}
        - --served-model-name=${MODEL_NAME}
        - --port=8000
        - --host=0.0.0.0
        - --dtype=half
        - --max-model-len=${MAX_MODEL_LEN}
        - --gpu-memory-utilization=${GPU_MEMORY_UTIL}
        - --enable-prefix-caching
        - --tensor-parallel-size=1
        - --trust-remote-code
        env:${HF_ENV}
        ports:
        - name: http
          containerPort: 8000
          protocol: TCP
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
            nvidia.com/gpu: "1"
          limits:
            cpu: "16"
            memory: "48Gi"
            nvidia.com/gpu: "1"
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 40
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE_PATH}
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${MODEL_NAME}
    app.kubernetes.io/part-of: llm-d
spec:
  selector:
    app: ${MODEL_NAME}
  ports:
  - name: http
    port: 8000
    targetPort: 8000
    protocol: TCP
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${MODEL_NAME}-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: ${MODEL_NAME}
EOF

echo "=== 7. Wait for EPP ready (至少 1/2 即可) ==="
for i in $(seq 1 30); do
  READY=$(kubectl get deployment/${MODEL_NAME}-endpoint-picker -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  if [ "${READY:-0}" -ge 1 ]; then
    echo "EPP ready: ${READY}/2"
    break
  fi
  echo "Waiting for EPP... ($i/30)"
  sleep 4
done

echo "=== 8. Wait for vLLM ready ==="
echo "  (模型加载最多需要 10 分钟，请耐心等待...)"
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=600s

echo ""
echo "=== Status ==="
kubectl get deployment,svc -n ${NAMESPACE} | grep -E "${MODEL_NAME}|NAME"
kubectl get inferencepools -n ${NAMESPACE} 2>/dev/null || true
kubectl get httproute -n ${NAMESPACE} 2>/dev/null || true

# 自动检测 Gateway NodePort
GATEWAY_NODE_PORT=$(kubectl get svc -n ${NAMESPACE} | grep "${GATEWAY_NAME}" | awk '{print $5}' | grep -oP '\d+(?=:80/)' | head -1)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

echo ""
echo "Done. Test with:"
if [ -n "$GATEWAY_NODE_PORT" ]; then
  echo "  curl http://${NODE_IP}:${GATEWAY_NODE_PORT}/v1/chat/completions \\"
else
  echo "  curl http://<gateway-ip>/v1/chat/completions \\"
fi
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
