#!/bin/bash
# deploy-model.sh — 部署 vLLM 模型到 llm-d standalone 集群
#
# 使用官方 Kustomize overlay，通过 label 与 router 关联
#
# Usage: bash deploy-model.sh [model-name] [model-path]
#
# 环境变量（可覆盖）：
#   NAMESPACE      K8s namespace，默认 llm-d-standalone
#   VLLM_IMAGE     vLLM 镜像，默认 vllm/vllm-openai:v0.8.5
#   REPLICAS       副本数，默认 1
#   REPO_ROOT      llm-d 仓库根目录，默认 /root/llm-d
#   MODEL_CACHE    hostPath 模型缓存根目录，默认 /root/models
set -e

NAMESPACE="${NAMESPACE:-llm-d-standalone}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.23.0}"
REPLICAS="${REPLICAS:-1}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"

# 默认模型：Qwen2.5-7B-Instruct（本地缓存）
MODEL_NAME="${1:-qwen25-7b-instruct}"
MODEL_PATH_RAW="${2:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"

# 自动解析 HF cache snapshot 路径
if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
  MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  echo "  Auto-resolved snapshot: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_PATH_RAW"
fi

echo "=== Deploying model: $MODEL_NAME ==="
echo "  Path:      $MODEL_PATH"
echo "  Image:     $VLLM_IMAGE"
echo "  Replicas:  $REPLICAS"
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

echo "=== Waiting for model ready (up to 10min) ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=600s

echo ""
echo "=== Status ==="
kubectl get pods,svc -n ${NAMESPACE}

# 获取访问入口
GUIDE_NAME="${GUIDE_NAME:-quickstart}"
EPP_IP=$(kubectl get svc ${GUIDE_NAME}-epp -n ${NAMESPACE} \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<epp-svc-ip>")

echo ""
echo "Done. Test with (run inside cluster):"
echo "  curl http://${EPP_IP}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
