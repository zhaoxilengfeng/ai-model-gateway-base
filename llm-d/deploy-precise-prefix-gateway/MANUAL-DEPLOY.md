# 手动部署指南

本文档将整个部署拆解为可逐条 `kubectl apply` / `helm install` 的 YAML 片段。
按章节顺序执行即可完成从零到两个模型可访问的完整部署。

---

## 前置说明

| 项 | 值 |
|----|-----|
| 集群入口节点 | `116.198.67.18`（master01） |
| GPU 节点 | `11.194.12.3`（h200-12-3，8× H200） |
| 推理 Namespace | `llm-d-precise-prefix-gw` |
| agentgateway controller Namespace | `agentgateway-system` |
| qwen25-7b NodePort | `31820` |
| glm-4-9b NodePort | `31161` |

**执行前检查：**
```bash
# 确认镜像已同步到 GPU 节点
kubectl get nodes
# 确认模型文件存在
ls /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/   # qwen（master01）
ssh root@11.194.12.3 "ls /home/data/model/glm-4-9b-chat/" # glm（GPU节点）
```

---

## 阶段一：全局基础设施（执行一次）

### 1-1. 安装 GIE CRD（InferencePool）

```bash
kubectl apply --server-side -f /root/deploy/llm-d-precise-prefix-gateway/gie-v1.5.0.yaml
```

验证：
```bash
kubectl get crd inferencepools.inference.networking.k8s.io
```

---

### 1-2. 安装 Agentgateway CRDs

```bash
kubectl apply --server-side \
  -f /root/deploy/llm-d-precise-prefix-gateway/agentgateway-crds/agentgateway.dev_agentgatewaybackends.yaml \
  -f /root/deploy/llm-d-precise-prefix-gateway/agentgateway-crds/agentgateway.dev_agentgatewayparameters.yaml \
  -f /root/deploy/llm-d-precise-prefix-gateway/agentgateway-crds/agentgateway.dev_agentgatewaypolicies.yaml
```

验证：
```bash
kubectl get crd | grep agentgateway
```

---

### 1-3. 安装 Agentgateway Controller（Helm）

```bash
helm upgrade --install agentgateway \
  /root/deploy/llm-d-precise-prefix-gateway/agentgateway/agentgateway \
  --namespace agentgateway-system --create-namespace \
  --set inferenceExtension.enabled=true \
  --set image.pullPolicy=IfNotPresent \
  --set controller.image.pullPolicy=IfNotPresent \
  --skip-crds \
  --wait --timeout=180s
```

验证：
```bash
kubectl get pods -n agentgateway-system
```

---

### 1-4. 创建推理 Namespace

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm-d-precise-prefix-gw
```

```bash
kubectl apply -f namespace.yaml
```

---

### 1-5. 创建 HuggingFace Token Secret

```yaml
# hf-token-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: llm-d-hf-token
  namespace: llm-d-precise-prefix-gw
type: Opaque
stringData:
  HF_TOKEN: "dummy"   # 当前模型均离线加载，填占位值即可；私有模型填真实 token
```

```bash
kubectl apply -f hf-token-secret.yaml
```

---

## 阶段二：qwen25-7b-instruct 推理池

### 2-1. Render（Tokenizer）Deployment + Service

```yaml
# qwen-render.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: precise-prefix-cache-routing-render
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: precise-prefix-cache-routing
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/component: vllm-render
      app.kubernetes.io/part-of: precise-prefix-cache-routing
  template:
    metadata:
      labels:
        app.kubernetes.io/component: vllm-render
        app.kubernetes.io/part-of: precise-prefix-cache-routing
    spec:
      automountServiceAccountToken: false
      containers:
      - name: vllm-render
        image: docker.io/vllm/vllm-openai-cpu:v0.23.0
        imagePullPolicy: IfNotPresent
        command: ["vllm", "launch", "render"]
        args:
        - "/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct"
        - "--port=8000"
        - "--served-model-name=qwen25-7b-instruct"
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
          httpGet: {path: /health, port: render-http}
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 30
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
      volumes:
      - name: model-cache
        hostPath:
          path: /root/models
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: precise-prefix-cache-routing-render
  namespace: llm-d-precise-prefix-gw
spec:
  selector:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: precise-prefix-cache-routing
  ports:
  - name: render-http
    port: 8000
    targetPort: render-http
    protocol: TCP
```

```bash
kubectl apply -f qwen-render.yaml
```

---

### 2-2. AgentgatewayParameters（固定 NodePort）

```yaml
# qwen-agentgateway-params.yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: precise-prefix-cache-routing-params
  namespace: llm-d-precise-prefix-gw
spec:
  service:
    spec:
      ports:
      - name: http
        port: 80
        targetPort: 80
        nodePort: 31820
        protocol: TCP
```

```bash
kubectl apply -f qwen-agentgateway-params.yaml
```

---

### 2-3. Gateway

```yaml
# qwen-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: precise-prefix-cache-routing-gateway
  namespace: llm-d-precise-prefix-gw
spec:
  gatewayClassName: agentgateway
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: precise-prefix-cache-routing-params
  listeners:
  - port: 80
    protocol: HTTP
    name: default
    allowedRoutes:
      namespaces:
        from: All
```

```bash
kubectl apply -f qwen-gateway.yaml

# 等待 Gateway 就绪
kubectl wait gateway/precise-prefix-cache-routing-gateway \
  -n llm-d-precise-prefix-gw \
  --for=jsonpath='{.status.conditions[?(@.type=="Programmed")].status}=True' \
  --timeout=60s
```

---

### 2-4. EPP RBAC

```yaml
# qwen-epp-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: precise-prefix-cache-routing-epp
    app.kubernetes.io/version: "v0.9.0"
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: precise-prefix-cache-routing-epp-leader-election
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: precise-prefix-cache-routing-epp-non-sa
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: ["inference.networking.x-k8s.io"]
  resources: ["inferenceobjectives", "inferencemodelrewrites"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["llm-d.ai"]
  resources: ["inferenceobjectives", "inferencemodelrewrites"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["inference.networking.k8s.io"]
  resources: ["inferencepools"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: precise-prefix-cache-routing-epp-sa
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: precise-prefix-cache-routing-epp-leader-election-binding
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: precise-prefix-cache-routing-epp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: precise-prefix-cache-routing-epp-leader-election
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: precise-prefix-cache-routing-epp-non-sa
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: precise-prefix-cache-routing-epp-non-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: precise-prefix-cache-routing-epp-sa
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: precise-prefix-cache-routing-epp-sa
```

```bash
kubectl apply -f qwen-epp-rbac.yaml
```

---

### 2-5. EPP ConfigMap（插件配置）

```yaml
# qwen-epp-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
data:
  precise-prefix-cache-routing-plugins.yaml: |
    apiVersion: llm-d.ai/v1alpha1
    kind: EndpointPickerConfig
    plugins:
      - type: token-producer
        parameters:
          modelName: qwen25-7b-instruct
          vllm:
            url: "http://precise-prefix-cache-routing-render:8000"
      - type: endpoint-notification-source
      - type: precise-prefix-cache-producer
        parameters:
          tokenProcessorConfig:
            blockSize: 64
          speculativeIndexing: true
          indexerConfig:
            kvBlockIndexConfig:
              enableMetrics: true
          kvEventsConfig:
            topicFilter: "kv@"
            engineType: "vllm"
            concurrency: 8
            discoverPods: true
            podDiscoveryConfig:
              socketPort: 5556
      - type: prefix-cache-scorer
        parameters:
          prefixMatchInfoProducerName: precise-prefix-cache-producer
      - type: kv-cache-utilization-scorer
      - type: queue-scorer
      - type: no-hit-lru-scorer
        parameters:
          prefixMatchInfoProducerName: precise-prefix-cache-producer
    dataLayer:
      sources:
        - pluginRef: endpoint-notification-source
          extractors:
            - pluginRef: precise-prefix-cache-producer
    schedulingProfiles:
      - name: default
        plugins:
          - pluginRef: kv-cache-utilization-scorer
            weight: 2.0
          - pluginRef: queue-scorer
            weight: 2.0
          - pluginRef: prefix-cache-scorer
            weight: 3.0
          - pluginRef: no-hit-lru-scorer
            weight: 2.0
  default-plugins.yaml: |
    apiVersion: llm-d.ai/v1alpha1
    kind: EndpointPickerConfig
    plugins:
    - type: queue-scorer
    - type: kv-cache-utilization-scorer
    - type: prefix-cache-scorer
    schedulingProfiles:
    - name: default
      plugins:
      - pluginRef: queue-scorer
        weight: 2
      - pluginRef: kv-cache-utilization-scorer
        weight: 2
      - pluginRef: prefix-cache-scorer
        weight: 3
```

```bash
kubectl apply -f qwen-epp-configmap.yaml
```

---

### 2-6. EPP Deployment + Service

```yaml
# qwen-epp.yaml
apiVersion: v1
kind: Service
metadata:
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: precise-prefix-cache-routing-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  selector:
    llm-d-router-gateway: precise-prefix-cache-routing-epp
  ports:
  - name: grpc-ext-proc
    protocol: TCP
    port: 9002
  - name: http-metrics
    protocol: TCP
    port: 9090
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8081
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: precise-prefix-cache-routing-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: precise-prefix-cache-routing-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  replicas: 2
  strategy:
    type: Recreate
  selector:
    matchLabels:
      llm-d-router-gateway: precise-prefix-cache-routing-epp
  template:
    metadata:
      labels:
        llm-d-router-gateway: precise-prefix-cache-routing-epp
    spec:
      serviceAccountName: precise-prefix-cache-routing-epp
      terminationGracePeriodSeconds: 130
      containers:
      - name: epp
        image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
        imagePullPolicy: IfNotPresent
        args:
        - --pool-name
        - precise-prefix-cache-routing
        - --pool-namespace
        - llm-d-precise-prefix-gw
        - --pool-group
        - "inference.networking.k8s.io"
        - --zap-encoder
        - "json"
        - --config-file
        - "/config/precise-prefix-cache-routing-plugins.yaml"
        - --ha-enable-leader-election
        - --grpc-health-port
        - "9003"
        - "--ha-enable-leader-election=false"
        - "--v=2"
        - --tracing=false
        resources:
          requests:
            cpu: "4"
            memory: 8Gi
          limits:
            memory: 16Gi
        ports:
        - name: grpc
          containerPort: 9002
        - name: grpc-health
          containerPort: 9003
        - name: metrics
          containerPort: 9090
        livenessProbe:
          grpc:
            port: 9003
            service: liveness
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          grpc:
            port: 9003
            service: readiness
          periodSeconds: 2
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              key: HF_TOKEN
              name: llm-d-hf-token
        volumeMounts:
        - name: plugins-config-volume
          mountPath: "/config"
      volumes:
      - name: plugins-config-volume
        configMap:
          name: precise-prefix-cache-routing-epp
```

```bash
kubectl apply -f qwen-epp.yaml

kubectl rollout status deployment/precise-prefix-cache-routing-epp \
  -n llm-d-precise-prefix-gw --timeout=120s
```

---

### 2-7. HTTPRoute + InferencePool

```yaml
# qwen-route-pool.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: precise-prefix-cache-routing
  namespace: llm-d-precise-prefix-gw
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: precise-prefix-cache-routing-gateway
  rules:
  - backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: precise-prefix-cache-routing
    matches:
    - path:
        type: PathPrefix
        value: /
    timeouts:
      request: 0s
---
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: precise-prefix-cache-routing
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: precise-prefix-cache-routing-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  targetPorts:
  - number: 8000
  appProtocol: "http"
  selector:
    matchLabels:
      llm-d.ai/guide: "precise-prefix-cache-routing"
  endpointPickerRef:
    name: precise-prefix-cache-routing-epp
    port:
      number: 9002
    failureMode: FailOpen
```

```bash
kubectl apply -f qwen-route-pool.yaml
```

---

### 2-8. qwen25-7b-instruct 模型 Deployment + Service

> GPU 共 8 张，与 glm 各占 4 张。独占时可设为 8。

```yaml
# qwen-model.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen25-7b-instruct
  namespace: llm-d-precise-prefix-gw
  labels:
    llm-d.ai/model: qwen25-7b-instruct
    llm-d.ai/guide: precise-prefix-cache-routing
spec:
  replicas: 4
  selector:
    matchLabels:
      llm-d.ai/model: qwen25-7b-instruct
      llm-d.ai/guide: precise-prefix-cache-routing
  template:
    metadata:
      labels:
        llm-d.ai/model: qwen25-7b-instruct
        llm-d.ai/guide: precise-prefix-cache-routing
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: modelserver
        image: vllm/vllm-openai:v0.23.0
        imagePullPolicy: IfNotPresent
        command: ["vllm", "serve"]
        args:
        - "/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct"
        - "--served-model-name=qwen25-7b-instruct"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--dtype=half"
        - "--max-model-len=32768"
        - "--gpu-memory-utilization=0.85"
        - "--enable-prefix-caching"
        - "--block-size=64"
        - "--kv-events-config"
        - '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@$(POD_IP):8000@qwen25-7b-instruct"}'
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
          path: /root/models
          type: DirectoryOrCreate
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: qwen25-7b-instruct
  namespace: llm-d-precise-prefix-gw
spec:
  selector:
    llm-d.ai/model: qwen25-7b-instruct
    llm-d.ai/guide: precise-prefix-cache-routing
  ports:
  - name: http
    port: 8000
    targetPort: 8000
  - name: kv-events
    port: 5556
    targetPort: 5556
    protocol: TCP
```

```bash
kubectl apply -f qwen-model.yaml

kubectl rollout status deployment/qwen25-7b-instruct \
  -n llm-d-precise-prefix-gw --timeout=600s

# EPP 重启以感知新 pod
kubectl rollout restart deployment/precise-prefix-cache-routing-epp \
  -n llm-d-precise-prefix-gw
kubectl rollout status deployment/precise-prefix-cache-routing-epp \
  -n llm-d-precise-prefix-gw --timeout=60s
```

---

## 阶段三：glm-4-9b 推理池

### 3-1. Render（Tokenizer）Deployment + Service

```yaml
# glm-render.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glm4-9b-pool-render
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: glm4-9b-pool
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/component: vllm-render
      app.kubernetes.io/part-of: glm4-9b-pool
  template:
    metadata:
      labels:
        app.kubernetes.io/component: vllm-render
        app.kubernetes.io/part-of: glm4-9b-pool
    spec:
      automountServiceAccountToken: false
      containers:
      - name: vllm-render
        image: docker.io/vllm/vllm-openai-cpu:v0.23.0
        imagePullPolicy: IfNotPresent
        command: ["vllm", "launch", "render"]
        args:
        - "/root/models/glm-4-9b-chat"
        - "--port=8000"
        - "--served-model-name=glm-4-9b"
        - "--trust-remote-code"
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
          httpGet: {path: /health, port: render-http}
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 30
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
      volumes:
      - name: model-cache
        hostPath:
          path: /home/data/model
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: glm4-9b-pool-render
  namespace: llm-d-precise-prefix-gw
spec:
  selector:
    app.kubernetes.io/component: vllm-render
    app.kubernetes.io/part-of: glm4-9b-pool
  ports:
  - name: render-http
    port: 8000
    targetPort: render-http
    protocol: TCP
```

```bash
kubectl apply -f glm-render.yaml
```

---

### 3-2. AgentgatewayParameters（固定 NodePort）

```yaml
# glm-agentgateway-params.yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: glm4-9b-pool-params
  namespace: llm-d-precise-prefix-gw
spec:
  service:
    spec:
      ports:
      - name: http
        port: 80
        targetPort: 80
        nodePort: 31161
        protocol: TCP
```

```bash
kubectl apply -f glm-agentgateway-params.yaml
```

---

### 3-3. Gateway

```yaml
# glm-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: glm4-9b-pool-gateway
  namespace: llm-d-precise-prefix-gw
spec:
  gatewayClassName: agentgateway
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: glm4-9b-pool-params
  listeners:
  - port: 80
    protocol: HTTP
    name: default
    allowedRoutes:
      namespaces:
        from: All
```

```bash
kubectl apply -f glm-gateway.yaml

kubectl wait gateway/glm4-9b-pool-gateway \
  -n llm-d-precise-prefix-gw \
  --for=jsonpath='{.status.conditions[?(@.type=="Programmed")].status}=True' \
  --timeout=60s
```

---

### 3-4. EPP RBAC

```yaml
# glm-epp-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: glm4-9b-pool-epp
    app.kubernetes.io/version: "v0.9.0"
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: glm4-9b-pool-epp-leader-election
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: glm4-9b-pool-epp-non-sa
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: ["inference.networking.x-k8s.io"]
  resources: ["inferenceobjectives", "inferencemodelrewrites"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["llm-d.ai"]
  resources: ["inferenceobjectives", "inferencemodelrewrites"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["inference.networking.k8s.io"]
  resources: ["inferencepools"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: glm4-9b-pool-epp-sa
  namespace: llm-d-precise-prefix-gw
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: glm4-9b-pool-epp-leader-election-binding
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: glm4-9b-pool-epp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: glm4-9b-pool-epp-leader-election
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: glm4-9b-pool-epp-non-sa
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: glm4-9b-pool-epp-non-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: glm4-9b-pool-epp-sa
  namespace: llm-d-precise-prefix-gw
subjects:
- kind: ServiceAccount
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: glm4-9b-pool-epp-sa
```

```bash
kubectl apply -f glm-epp-rbac.yaml
```

---

### 3-5. EPP ConfigMap（插件配置）

```yaml
# glm-epp-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
data:
  precise-prefix-cache-routing-plugins.yaml: |
    apiVersion: llm-d.ai/v1alpha1
    kind: EndpointPickerConfig
    plugins:
      - type: token-producer
        parameters:
          modelName: glm-4-9b
          vllm:
            url: "http://glm4-9b-pool-render:8000"
      - type: endpoint-notification-source
      - type: precise-prefix-cache-producer
        parameters:
          tokenProcessorConfig:
            blockSize: 64
          speculativeIndexing: true
          indexerConfig:
            kvBlockIndexConfig:
              enableMetrics: true
          kvEventsConfig:
            topicFilter: "kv@"
            engineType: "vllm"
            concurrency: 8
            discoverPods: true
            podDiscoveryConfig:
              socketPort: 5556
      - type: prefix-cache-scorer
        parameters:
          prefixMatchInfoProducerName: precise-prefix-cache-producer
      - type: kv-cache-utilization-scorer
      - type: queue-scorer
      - type: no-hit-lru-scorer
        parameters:
          prefixMatchInfoProducerName: precise-prefix-cache-producer
    dataLayer:
      sources:
        - pluginRef: endpoint-notification-source
          extractors:
            - pluginRef: precise-prefix-cache-producer
    schedulingProfiles:
      - name: default
        plugins:
          - pluginRef: kv-cache-utilization-scorer
            weight: 2.0
          - pluginRef: queue-scorer
            weight: 2.0
          - pluginRef: prefix-cache-scorer
            weight: 3.0
          - pluginRef: no-hit-lru-scorer
            weight: 2.0
```

```bash
kubectl apply -f glm-epp-configmap.yaml
```

---

### 3-6. EPP Deployment + Service

```yaml
# glm-epp.yaml
apiVersion: v1
kind: Service
metadata:
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: glm4-9b-pool-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  selector:
    llm-d-router-gateway: glm4-9b-pool-epp
  ports:
  - name: grpc-ext-proc
    protocol: TCP
    port: 9002
  - name: http-metrics
    protocol: TCP
    port: 9090
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8081
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glm4-9b-pool-epp
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: glm4-9b-pool-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  replicas: 2
  strategy:
    type: Recreate
  selector:
    matchLabels:
      llm-d-router-gateway: glm4-9b-pool-epp
  template:
    metadata:
      labels:
        llm-d-router-gateway: glm4-9b-pool-epp
    spec:
      serviceAccountName: glm4-9b-pool-epp
      terminationGracePeriodSeconds: 130
      containers:
      - name: epp
        image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
        imagePullPolicy: IfNotPresent
        args:
        - --pool-name
        - glm4-9b-pool
        - --pool-namespace
        - llm-d-precise-prefix-gw
        - --pool-group
        - "inference.networking.k8s.io"
        - --zap-encoder
        - "json"
        - --config-file
        - "/config/precise-prefix-cache-routing-plugins.yaml"
        - --ha-enable-leader-election
        - --grpc-health-port
        - "9003"
        - "--ha-enable-leader-election=false"
        - "--v=2"
        - --tracing=false
        resources:
          requests:
            cpu: "4"
            memory: 8Gi
          limits:
            memory: 16Gi
        ports:
        - name: grpc
          containerPort: 9002
        - name: grpc-health
          containerPort: 9003
        - name: metrics
          containerPort: 9090
        livenessProbe:
          grpc:
            port: 9003
            service: liveness
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          grpc:
            port: 9003
            service: readiness
          periodSeconds: 2
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              key: HF_TOKEN
              name: llm-d-hf-token
        volumeMounts:
        - name: plugins-config-volume
          mountPath: "/config"
      volumes:
      - name: plugins-config-volume
        configMap:
          name: glm4-9b-pool-epp
```

```bash
kubectl apply -f glm-epp.yaml

kubectl rollout status deployment/glm4-9b-pool-epp \
  -n llm-d-precise-prefix-gw --timeout=120s
```

---

### 3-7. HTTPRoute + InferencePool

```yaml
# glm-route-pool.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: glm4-9b-pool
  namespace: llm-d-precise-prefix-gw
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: glm4-9b-pool-gateway
  rules:
  - backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: glm4-9b-pool
    matches:
    - path:
        type: PathPrefix
        value: /
    timeouts:
      request: 0s
---
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: glm4-9b-pool
  namespace: llm-d-precise-prefix-gw
  labels:
    app.kubernetes.io/name: glm4-9b-pool-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  targetPorts:
  - number: 8000
  appProtocol: "http"
  selector:
    matchLabels:
      llm-d.ai/guide: "glm4-9b-pool"
  endpointPickerRef:
    name: glm4-9b-pool-epp
    port:
      number: 9002
    failureMode: FailOpen
```

```bash
kubectl apply -f glm-route-pool.yaml
```

---

### 3-8. glm-4-9b 模型 Deployment + Service

```yaml
# glm-model.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glm-4-9b
  namespace: llm-d-precise-prefix-gw
  labels:
    llm-d.ai/model: glm-4-9b
    llm-d.ai/guide: glm4-9b-pool
spec:
  replicas: 4
  selector:
    matchLabels:
      llm-d.ai/model: glm-4-9b
      llm-d.ai/guide: glm4-9b-pool
  template:
    metadata:
      labels:
        llm-d.ai/model: glm-4-9b
        llm-d.ai/guide: glm4-9b-pool
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: modelserver
        image: vllm/vllm-openai:v0.23.0
        imagePullPolicy: IfNotPresent
        command: ["vllm", "serve"]
        args:
        - "/home/data/model/glm-4-9b-chat"
        - "--served-model-name=glm-4-9b"
        - "--host=0.0.0.0"
        - "--port=8000"
        - "--dtype=half"
        - "--max-model-len=8192"
        - "--gpu-memory-utilization=0.85"
        - "--trust-remote-code"
        - "--enable-prefix-caching"
        - "--block-size=64"
        - "--kv-events-config"
        - '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@$(POD_IP):8000@glm-4-9b"}'
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
          mountPath: /home/data/model/glm-4-9b-chat
        - name: shm
          mountPath: /dev/shm
      volumes:
      - name: model-cache
        hostPath:
          path: /home/data/model/glm-4-9b-chat
          type: Directory
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: glm-4-9b
  namespace: llm-d-precise-prefix-gw
spec:
  selector:
    llm-d.ai/model: glm-4-9b
    llm-d.ai/guide: glm4-9b-pool
  ports:
  - name: http
    port: 8000
    targetPort: 8000
  - name: kv-events
    port: 5556
    targetPort: 5556
    protocol: TCP
```

```bash
kubectl apply -f glm-model.yaml

kubectl rollout status deployment/glm-4-9b \
  -n llm-d-precise-prefix-gw --timeout=600s

# EPP 重启以感知新 pod
kubectl rollout restart deployment/glm4-9b-pool-epp \
  -n llm-d-precise-prefix-gw
kubectl rollout status deployment/glm4-9b-pool-epp \
  -n llm-d-precise-prefix-gw --timeout=60s
```

---

## 验证

```bash
# qwen25-7b-instruct
curl http://116.198.67.18:31820/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'

# glm-4-9b
curl http://116.198.67.18:31161/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-4-9b","messages":[{"role":"user","content":"你好"}],"max_tokens":20}'
```

---

## 卸载

```bash
# 销毁模型 pod
kubectl delete deployment qwen25-7b-instruct glm-4-9b -n llm-d-precise-prefix-gw
kubectl delete service qwen25-7b-instruct glm-4-9b -n llm-d-precise-prefix-gw

# 卸载 qwen pool
helm uninstall precise-prefix-cache-routing -n llm-d-precise-prefix-gw 2>/dev/null || true
kubectl delete deployment precise-prefix-cache-routing-render -n llm-d-precise-prefix-gw
kubectl delete service precise-prefix-cache-routing-render -n llm-d-precise-prefix-gw
kubectl delete gateway precise-prefix-cache-routing-gateway -n llm-d-precise-prefix-gw
kubectl delete agentgatewayparameters precise-prefix-cache-routing-params -n llm-d-precise-prefix-gw

# 卸载 glm pool
helm uninstall glm4-9b-pool -n llm-d-precise-prefix-gw 2>/dev/null || true
kubectl delete deployment glm4-9b-pool-render -n llm-d-precise-prefix-gw
kubectl delete service glm4-9b-pool-render -n llm-d-precise-prefix-gw
kubectl delete gateway glm4-9b-pool-gateway -n llm-d-precise-prefix-gw
kubectl delete agentgatewayparameters glm4-9b-pool-params -n llm-d-precise-prefix-gw

# 卸载全局基础设施
helm uninstall agentgateway -n agentgateway-system
kubectl delete namespace llm-d-precise-prefix-gw agentgateway-system
```
