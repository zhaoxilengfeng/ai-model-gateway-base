#!/bin/bash
set -e

# Usage: bash deploy-model-internal.sh <model-name> <hf-repo> [replicas]
# Example: bash deploy-model-internal.sh qwen25-7b-instruct-v2 Qwen/Qwen2.5-7B-Instruct 2
#
# replicas controls how many GPU nodes to use. Pods are automatically spread
# across nodes (one per node) via podAntiAffinity.
#
# Gateway endpoint is read from env var GATEWAY_ENDPOINT (host:port).
# If not set, falls back to NodePort auto-detection from the cluster.
#
# Examples:
#   GATEWAY_ENDPOINT=10.100.134.246:80 bash deploy-model-internal.sh ...   # ClusterIP
#   GATEWAY_ENDPOINT=192.168.1.10:8080 bash deploy-model-internal.sh ...   # any host:port
#   bash deploy-model-internal.sh ...                                       # auto NodePort

MODEL_NAME="${1:?Usage: $0 <model-name> <hf-repo> [replicas]}"
HF_REPO="${2:?Usage: $0 <model-name> <hf-repo> [replicas]}"
REPLICAS="${3:-1}"

# Resolve gateway endpoint
if [ -n "$GATEWAY_ENDPOINT" ]; then
  GATEWAY_HOST="$GATEWAY_ENDPOINT"
  GATEWAY_MODE="env"
else
  # Fallback: detect NodePort from cluster
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  NODE_PORT=$(kubectl get svc -n envoy-gateway-system \
    -l "gateway.envoyproxy.io/owning-gateway-name=aibrix-eg" \
    -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
  if [ -z "$NODE_IP" ] || [ -z "$NODE_PORT" ]; then
    echo "ERROR: GATEWAY_ENDPOINT not set and NodePort auto-detection failed." >&2
    echo "  Set it explicitly: GATEWAY_ENDPOINT=<host>:<port> bash $0 ..." >&2
    exit 1
  fi
  GATEWAY_HOST="${NODE_IP}:${NODE_PORT}"
  GATEWAY_MODE="auto-nodeport"
fi

echo "=== Deploying model: $MODEL_NAME ==="
echo "  HF repo:  $HF_REPO"
echo "  Replicas: $REPLICAS"
echo "  Gateway:  $GATEWAY_HOST ($GATEWAY_MODE)"

echo "=== 1. Create Deployment ==="
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $MODEL_NAME
  namespace: default
  labels:
    model.aibrix.ai/name: $MODEL_NAME
    model.aibrix.ai/port: "8000"
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      model.aibrix.ai/name: $MODEL_NAME
      model.aibrix.ai/port: "8000"
  template:
    metadata:
      labels:
        model.aibrix.ai/name: $MODEL_NAME
        model.aibrix.ai/port: "8000"
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                model.aibrix.ai/name: $MODEL_NAME
            topologyKey: kubernetes.io/hostname
      containers:
      - name: vllm-openai
        image: vllm/vllm-openai:v0.6.6.post1
        imagePullPolicy: IfNotPresent
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
        - --model
        - $HF_REPO
        - --served-model-name
        - $MODEL_NAME
        - --host
        - "0.0.0.0"
        - --port
        - "8000"
        - --trust-remote-code
        - --max-model-len
        - "32768"
        - --enable-prefix-caching
        env:
        - name: HF_ENDPOINT
          value: "https://hf-mirror.com"
        - name: HF_HOME
          value: "/models"
        ports:
        - containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
            memory: "16Gi"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 360
        volumeMounts:
        - mountPath: /models
          name: model-cache
      volumes:
      - name: model-cache
        hostPath:
          path: /root/models
          type: DirectoryOrCreate
EOF

echo "=== 2. Create Service ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $MODEL_NAME
  namespace: default
spec:
  selector:
    model.aibrix.ai/name: $MODEL_NAME
    model.aibrix.ai/port: "8000"
  ports:
  - port: 8000
    targetPort: 8000
EOF

echo "=== 3. Wait for HTTPRoute (auto-created by controller) ==="
for i in $(seq 1 30); do
  if kubectl get httproute -n aibrix-system "${MODEL_NAME}-router" &>/dev/null; then
    echo "HTTPRoute created: ${MODEL_NAME}-router"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 2
done

echo ""
echo "=== Status ==="
kubectl get deployment,svc -n default | grep "$MODEL_NAME"
kubectl get httproute -n aibrix-system | grep "$MODEL_NAME"

echo ""
echo "Done. Test with:"
echo "  curl http://$GATEWAY_HOST/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
