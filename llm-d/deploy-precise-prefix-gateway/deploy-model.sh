#!/bin/bash
# deploy-model.sh — 部署 vLLM 模型到 precise-prefix-cache-routing gateway 集群
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
REPLICAS="${REPLICAS:-2}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"

MODEL_NAME="${1:-qwen25-7b-instruct}"
MODEL_PATH_RAW="${2:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"

if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
  MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  echo "  Auto-resolved snapshot: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_PATH_RAW"
fi

SERVED_MODEL="${SERVED_MODEL:-${MODEL_NAME}}"

echo "=== Deploying model: ${MODEL_NAME} ==="
echo "  Path:        ${MODEL_PATH}"
echo "  Image:       ${VLLM_IMAGE}"
echo "  Namespace:   ${NAMESPACE}"
echo "  Replicas:    ${REPLICAS}"

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
        - "--max-model-len=32768"
        - "--gpu-memory-utilization=0.85"
        - "--enable-prefix-caching"
        # ── 精准前缀哈希路由必须项 ──────────────────────────────────────────
        - "--block-size=64"
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

# 重启 EPP 确保感知新 pod（精准前缀路由要求）
echo "=== Restart EPP to pick up new vLLM pods ==="
kubectl rollout restart deployment/${GUIDE_NAME}-epp -n ${NAMESPACE}
kubectl rollout status deployment/${GUIDE_NAME}-epp -n ${NAMESPACE} --timeout=60s

NODE_PORT=$(kubectl get svc llm-d-inference-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "<nodeport>")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

echo ""
echo "Done. Test with:"
echo "  curl http://${NODE_IP}:${NODE_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${SERVED_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
