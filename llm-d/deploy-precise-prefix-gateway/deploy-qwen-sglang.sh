#!/bin/bash
# deploy-qwen-sglang.sh — 用 sglang 部署 qwen25-7b-instruct（8 副本，各 1 GPU）
#
# 对标 deploy-model.sh（vLLM 版），用于与 vLLM 进行性能对比测试。
# 需要 sglang v0.4.7+ 支持 --kv-events-config（PR #6805）。
#
# 用法:
#   bash deploy-qwen-sglang.sh
#   REPLICAS=4 bash deploy-qwen-sglang.sh  # 自定义副本数

set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
# sglang 镜像：v0.4.7+ 支持 --kv-events-config
SGLANG_IMAGE="${SGLANG_IMAGE:-m.daocloud.io/docker.io/lmsysorg/sglang:latest}"
REPLICAS="${REPLICAS:-8}"
MODEL_PATH="${MODEL_PATH:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"

MODEL_NAME="qwen25-7b-instruct-sglang"
SERVED_MODEL="qwen25-7b-instruct"   # served-model-name 与 vLLM 一致，EPP 统一识别

echo "=== 部署 qwen25-7b-instruct（sglang）==="
echo "  镜像:        $SGLANG_IMAGE"
echo "  副本数:      $REPLICAS"
echo "  模型路径:    $MODEL_PATH"
echo "  Namespace:   $NAMESPACE"

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
      - name: sglang
        image: ${SGLANG_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["python3", "-m", "sglang.launch_server"]
        args:
        - "--model-path=${MODEL_PATH}"
        - "--served-model-name=${SERVED_MODEL}"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--tp=1"
        - "--context-length=32768"
        - "--mem-fraction-static=0.85"
        - "--trust-remote-code"
        - "--enable-metrics"
        - "--log-level=info"
        - "--kv-events-config={\"enable_kv_cache_events\":true,\"publisher\":\"zmq\",\"endpoint\":\"tcp://*:5556\",\"topic\":\"kv@\$(POD_IP):8000@${SERVED_MODEL}\"}"
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        - name: DO_NOT_TRACK
          value: "1"
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
          initialDelaySeconds: 60
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

echo ""
echo "=== 等待 pod 调度 ==="
kubectl rollout status deployment/${MODEL_NAME} -n ${NAMESPACE} --timeout=30s 2>/dev/null || true

POD=$(kubectl get pod -n ${NAMESPACE} -l app=${MODEL_NAME} --no-headers 2>/dev/null | head -1 | awk '{print $1}')
echo ""
echo "=== 部署完成 ==="
echo "  sglang 启动约需 3-5 分钟（qwen25-7b 比 GLM 快很多）"
echo ""
echo "查看日志: kubectl logs -n ${NAMESPACE} -l llm-d.ai/model=${MODEL_NAME} -f"
echo ""
echo "就绪后测试:"
echo "  curl http://116.198.67.18:31273/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${SERVED_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":50}'"
