#!/bin/bash
set -e

# Usage: bash deploy-model.sh <model-name> <hf-repo> [replicas] [node]
# Example: bash deploy-model.sh qwen25-7b-instruct-v2 Qwen/Qwen2.5-7B-Instruct 1

MODEL_NAME="${1:?Usage: $0 <model-name> <hf-repo> [replicas] [node]}"
HF_REPO="${2:?Usage: $0 <model-name> <hf-repo> [replicas] [node]}"
REPLICAS="${3:-1}"
NODE="${4:-}"

echo "=== Deploying model: $MODEL_NAME ==="
echo "  HF repo:  $HF_REPO"
echo "  Replicas: $REPLICAS"
echo "  Node:     ${NODE:-auto}"

# Build nodeSelector block if node specified
NODE_SELECTOR=""
if [ -n "$NODE" ]; then
  NODE_SELECTOR="
      nodeSelector:
        kubernetes.io/hostname: $NODE"
fi

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
    spec:$NODE_SELECTOR
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
echo "  curl http://10.0.0.2:32226/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":20}'"
