#!/bin/bash
# install.sh — 安装 precise-prefix-cache-routing（精准前缀哈希路由）
#
# 路由模式：Standalone（EPP 内置 Envoy sidecar），不依赖外部 Gateway
# 核心机制：vLLM 通过 ZMQ :5556 发布 KV 块事件 → EPP 订阅并构建哈希索引
#           → 请求到来时按前缀哈希精准命中已缓存块最多的 pod
set -e

GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-precise-prefix}"
MODEL_CACHE="${MODEL_CACHE:-/root/models}"
# render 模型路径：必须是本地实际 snapshot 路径，render 用它加载 tokenizer
# 与 deploy-model.sh 的 MODEL_PATH 保持一致（同一份 tokenizer 文件）
RENDER_MODEL_PATH="${RENDER_MODEL_PATH:-}"

ROUTER_CHART_DIR="$DEPLOY_DIR/llm-d-router-standalone"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

[ -f "$ROUTER_CHART_DIR/Chart.yaml" ] || { echo "ERROR: 请先运行 prepare.sh" >&2; exit 1; }
[ -f "$GIE_YAML" ]                    || { echo "ERROR: 请先运行 prepare.sh" >&2; exit 1; }

# 自动解析 render 模型路径（与 deploy-model.sh 逻辑相同）
if [ -z "$RENDER_MODEL_PATH" ]; then
  MODEL_PATH_RAW="${MODEL_PATH_RAW:-/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct}"
  if [ -d "${MODEL_PATH_RAW}/snapshots" ]; then
    RENDER_MODEL_PATH=$(ls -td "${MODEL_PATH_RAW}/snapshots"/*/ 2>/dev/null | head -1 | sed 's|/$||')
  else
    RENDER_MODEL_PATH="$MODEL_PATH_RAW"
  fi
  echo "  render model path: $RENDER_MODEL_PATH"
fi

echo "=== 1. Install GIE CRDs ==="
kubectl apply --server-side -f "$GIE_YAML"

echo "=== 2. Create namespace ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 3. Create HF token secret ==="
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN:-dummy}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== 4. Deploy render (tokenizer) Service ==="
# render 用 vllm launch render 加载本地 tokenizer，不做推理、不占 GPU
# 必须挂载 hostPath 并使用本地 snapshot 路径，否则会尝试联网下载 tokenizer 失败
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
        # served-model-name 必须与 EPP token-producer.modelName 以及 vLLM --served-model-name 一致
        - "--served-model-name=${SERVED_MODEL:-qwen25-7b-instruct}"
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
          httpGet:
            path: /health
            port: render-http
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

echo "=== 5. Install llm-d-router-standalone (EPP + Envoy sidecar) ==="
helm upgrade --install "${GUIDE_NAME}" "$ROUTER_CHART_DIR" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout=180s

echo ""
echo "=== Verify ==="
kubectl get pods -n "${NAMESPACE}"
kubectl get inferencepool -n "${NAMESPACE}"

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<pending>")
echo ""
echo "Done. 下一步运行 deploy-model.sh 部署模型。"
echo "EPP ClusterIP: http://${EPP_IP}"
