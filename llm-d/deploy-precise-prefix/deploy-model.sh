#!/bin/bash
# deploy-model.sh — 部署 vLLM 模型到 precise-prefix-cache-routing 集群
#
# 关键差异（相比 optimized-baseline）：
#   1. 启用 --kv-events-config：vLLM 通过 ZMQ TCP :5556 发布 KV 块事件
#   2. --block-size=64 必须与 EPP precise-prefix-cache-producer blockSize 一致
#   3. 暴露 containerPort 5556（kv-events），EPP 通过 pod-discovery 订阅每个 pod
set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
REPLICAS="${REPLICAS:-1}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"

MODEL_NAME="${1:-qwen25-7b-instruct}"
MODEL_PATH_RAW="${2:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"

if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
  MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  echo "  Auto-resolved snapshot: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_PATH_RAW"
fi

# 模型名用于 vLLM KV 事件 topic（须与 EPP token-producer modelName 一致）
# 官方示例用 "Qwen/Qwen3-32B"，本地部署改为实际 served-model-name
SERVED_MODEL="${SERVED_MODEL:-${MODEL_NAME}}"

echo "=== Deploying model: ${MODEL_NAME} ==="
echo "  Path:        ${MODEL_PATH}"
echo "  Image:       ${VLLM_IMAGE}"
echo "  Namespace:   ${NAMESPACE}"
echo "  served-name: ${SERVED_MODEL}"

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    llm-d.ai/model: ${MODEL_NAME}
    llm-d.ai/guide: ${GUIDE_NAME}     # InferencePool selector 匹配此 label
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      llm-d.ai/model: ${MODEL_NAME}
      llm-d.ai/guide: ${GUIDE_NAME}
  template:
    metadata:
      labels:
        llm-d.ai/model: ${MODEL_NAME}
        llm-d.ai/guide: ${GUIDE_NAME}
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: modelserver
        image: ${VLLM_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["vllm", "serve"]
        args:
        - "${MODEL_PATH}"
        - "--served-model-name=${SERVED_MODEL}"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--dtype=half"
        - "--max-model-len=8192"
        - "--gpu-memory-utilization=0.85"
        - "--enable-prefix-caching"
        # ── 精准前缀哈希路由必须项 ──────────────────────────────────────────
        # block-size 必须与 EPP precise-prefix-cache-producer blockSize=64 一致
        - "--block-size=64"
        # 启用 KV 块事件，通过 ZMQ TCP :5556 向 EPP 实时推送 KV cache 状态
        - "--kv-events-config"
        - '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@\$(POD_IP):8000@${SERVED_MODEL}"}'
        env:
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        ports:
        - name: http
          containerPort: 8000
        # EPP 通过 pod-discovery 直连每个 pod 的 ZMQ socket 订阅 KV 事件
        - name: kv-events
          containerPort: 5556
          protocol: TCP
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
            memory: "16Gi"
        startupProbe:
          httpGet: {path: /health, port: 8000}
          initialDelaySeconds: 30
          periodSeconds: 15
          failureThreshold: 40
        readinessProbe:
          httpGet: {path: /health, port: 8000}
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          httpGet: {path: /health, port: 8000}
          initialDelaySeconds: 120
          periodSeconds: 30
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
        - name: shm
          mountPath: /dev/shm
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE}
          type: DirectoryOrCreate
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    llm-d.ai/model: ${MODEL_NAME}
    llm-d.ai/guide: ${GUIDE_NAME}
  ports:
  - name: http
    port: 8000
    targetPort: 8000
  - name: kv-events
    port: 5556
    targetPort: 5556
    protocol: TCP
EOF

echo "=== Waiting for model ready ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=600s

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<epp-ip>")

echo ""
echo "Done. Test with:"
echo "  curl http://${EPP_IP}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${SERVED_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
