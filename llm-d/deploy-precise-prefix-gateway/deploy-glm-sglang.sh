#!/bin/bash
# deploy-glm-sglang.sh — 用 sglang 容器镜像在 K8s 上部署 GLM-5.2-FP8 模型
#
# 模型路径: /home/data/model/GLM-5.2-FP8（704G，141 个 safetensors 分片）
# 镜像:     m.daocloud.io/docker.io/lmsysorg/sglang:latest（v0.5.15.post1）
# GPU:      8× NVIDIA H200（143G），tensor_parallel_size=8
set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
MODEL_NAME="${MODEL_NAME:-glm-5-2-fp8}"
SERVED_MODEL="${SERVED_MODEL:-glm-5-2-fp8}"
MODEL_PATH="${MODEL_PATH:-/home/data/model/GLM-5.2-FP8}"
MODEL_CACHE_DIR="${MODEL_CACHE_DIR:-/home/data/model}"
SGLANG_IMAGE="${SGLANG_IMAGE:-m.daocloud.io/docker.io/lmsysorg/sglang:latest}"
TP_SIZE="${TP_SIZE:-8}"
HOST_PORT="${HOST_PORT:-30001}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.92}"

echo "=== 部署 GLM-5.2-FP8（sglang）==="
echo "  模型:        $MODEL_NAME"
echo "  路径:        $MODEL_PATH"
echo "  镜像:        $SGLANG_IMAGE"
echo "  Namespace:   $NAMESPACE"
echo "  TP Size:     $TP_SIZE"
echo "  NodePort:    $HOST_PORT"

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${MODEL_NAME}
    model-framework: sglang
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${MODEL_NAME}
  template:
    metadata:
      labels:
        app: ${MODEL_NAME}
        model-framework: sglang
        llm-d.ai/guide: precise-prefix-cache-routing
        llm-d.ai/engine-type: sglang
    spec:
      nodeSelector:
        kubernetes.io/hostname: h200-12-3
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: sglang
        image: ${SGLANG_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["python3", "-m", "sglang.launch_server"]
        args:
        - "--model-path=${MODEL_PATH}"
        - "--served-model-name=${SERVED_MODEL}"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--tp=${TP_SIZE}"
        - "--context-length=${MAX_MODEL_LEN}"
        - "--mem-fraction-static=${GPU_MEMORY_UTIL}"
        - "--trust-remote-code"
        - "--chat-template=${MODEL_PATH}/chat_template.jinja"
        - "--enable-metrics"
        - "--log-level=info"
        env:
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
        ports:
        - name: http
          containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: "${TP_SIZE}"
          requests:
            nvidia.com/gpu: "${TP_SIZE}"
            memory: "32Gi"
        startupProbe:
          timeoutSeconds: 30
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 20
          failureThreshold: 60
        readinessProbe:
          timeoutSeconds: 30
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 15
          failureThreshold: 10
        livenessProbe:
          timeoutSeconds: 30
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 180
          periodSeconds: 30
        volumeMounts:
        - name: model-cache
          mountPath: /home/data/model
        - name: shm
          mountPath: /dev/shm
      volumes:
      - name: model-cache
        hostPath:
          path: ${MODEL_CACHE_DIR}
          type: DirectoryOrCreate
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 64Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: ${MODEL_NAME}
  ports:
  - name: http
    port: 8000
    targetPort: 8000
    nodePort: ${HOST_PORT}
    protocol: TCP
EOF

echo ""
echo "=== 等待 pod 调度 ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=30s 2>/dev/null || true

POD=$(kubectl get pod -n ${NAMESPACE} -l app=${MODEL_NAME} --no-headers | head -1 | awk '{print $1}')
echo ""
echo "=== 部署完成 ==="
echo "  Pod:         ${POD}"
echo "  模型加载中，GLM-5.2-FP8 需要约 5-10 分钟加载到 8 张 H200"
echo ""
echo "查看加载进度:"
echo "  kubectl logs -n ${NAMESPACE} ${POD} -f"
echo ""
echo "就绪后访问地址:"
NODE_IP=$(kubectl get node h200-12-3 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "11.194.12.3")
echo "  http://${NODE_IP}:${HOST_PORT}/v1/chat/completions"
echo "  http://116.198.67.18:${HOST_PORT}/v1/chat/completions"
echo ""
echo "测试命令:"
echo "  curl http://116.198.67.18:${HOST_PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${SERVED_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":100}'"
