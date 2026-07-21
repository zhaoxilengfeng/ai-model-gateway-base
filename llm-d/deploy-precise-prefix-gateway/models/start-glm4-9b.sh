#!/bin/bash
# start-glm4-9b.sh — 启动 GLM-4-9B（vLLM，2副本，各1×H200）
#
# 模型路径：GPU 节点 /home/data/model/glm-4-9b-chat（数据盘）
# 注意事项：
#   1. volume hostPath 和 mountPath 必须都设为 /home/data/model/glm-4-9b-chat
#      （不能用 symlink，vLLM 会调用 realpath 解析后重新验证）
#   2. 必须加 --trust-remote-code（GLM-4 有自定义模型代码）
#   3. MODEL_CACHE=/home/data/model/glm-4-9b-chat（不是默认的 /root/models）

set -e
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
REPLICAS="${REPLICAS:-2}"
MODEL_PATH="/home/data/model/glm-4-9b-chat"
SERVED_MODEL="glm-4-9b"
MODEL_NAME="glm-4-9b"

echo "=== 部署 GLM-4-9B (vLLM) ==="
echo "  模型:     $MODEL_NAME"
echo "  路径:     $MODEL_PATH"
echo "  副本数:   $REPLICAS"
echo "  Namespace: $NAMESPACE"

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    llm-d.ai/model: ${MODEL_NAME}
    llm-d.ai/guide: ${GUIDE_NAME}
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
        - "--trust-remote-code"
        - "--enable-prefix-caching"
        - "--block-size=64"
        - "--kv-events-config"
        - '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@$(POD_IP):8000@${SERVED_MODEL}"}'
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
          timeoutSeconds: 30
          initialDelaySeconds: 30
          periodSeconds: 15
          failureThreshold: 40
        readinessProbe:
          httpGet: {path: /health, port: 8000}
          timeoutSeconds: 30
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          httpGet: {path: /health, port: 8000}
          timeoutSeconds: 30
          initialDelaySeconds: 120
          periodSeconds: 30
        volumeMounts:
        - name: model-cache
          mountPath: ${MODEL_PATH}
        - name: shm
          mountPath: /dev/shm
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_PATH}
          type: Directory
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

echo ""
echo "=== 等待 pod 调度 ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=30s 2>/dev/null || true

echo ""
echo "=== 部署完成，GLM-4-9B 加载约 2-3 分钟 ==="
echo "测试命令:"
echo "  curl http://116.198.67.18:31273/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"glm-4-9b\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":50}'"
