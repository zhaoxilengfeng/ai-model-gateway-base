#!/bin/bash
# deploy-model.sh — 部署 vLLM 模型到 llm-d gateway 集群
#
# Usage: bash deploy-model.sh [model-name] [model-path]
set -e

NAMESPACE="${NAMESPACE:-llm-d-gateway}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}"
REPLICAS="${REPLICAS:-1}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"
GUIDE_NAME="${GUIDE_NAME:-quickstart}"

MODEL_NAME="${1:-qwen25-7b-instruct}"
MODEL_PATH_RAW="${2:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"

if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
  MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  echo "  Auto-resolved snapshot: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_PATH_RAW"
fi

echo "=== Deploying model: $MODEL_NAME ==="
echo "  Path:      $MODEL_PATH"
echo "  Image:     $VLLM_IMAGE"
echo "  Namespace: $NAMESPACE"

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    llm-d.ai/model: ${MODEL_NAME}
    llm-d.ai/guide: optimized-baseline
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      llm-d.ai/model: ${MODEL_NAME}
      llm-d.ai/guide: optimized-baseline
  template:
    metadata:
      labels:
        llm-d.ai/model: ${MODEL_NAME}
        llm-d.ai/guide: optimized-baseline
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
        - "--served-model-name=${MODEL_NAME}"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--dtype=half"
        - "--max-model-len=8192"
        - "--gpu-memory-utilization=0.85"
        - "--enable-prefix-caching"
        env:
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        ports:
        - name: http
          containerPort: 8000
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
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE}
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    llm-d.ai/model: ${MODEL_NAME}
    llm-d.ai/guide: optimized-baseline
  ports:
  - name: http
    port: 8000
    targetPort: 8000
EOF

echo "=== Waiting for model ready ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=600s

# 获取 NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
NODE_PORT=$(kubectl get svc -n agentgateway-system \
  -l "gateway.networking.k8s.io/gateway-name=${GUIDE_NAME}-gateway" \
  -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "<nodeport>")

echo ""
echo "Done. Test with:"
echo "  curl http://${NODE_IP}:${NODE_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
