# llm-d Gateway 模式纯 YAML 部署手册

本文将 `install.sh` + `deploy-model.sh` 中所有 Helm/脚本操作转换为等价的 YAML 文件，使得无需 Helm 也可完整部署 llm-d gateway 模式。

> **前置条件**
> - 已安装 kubectl，能访问目标集群
> - 各 worker 节点已导入所需容器镜像（见 `downlowd-image.sh`）
> - 已通过 `prepare.sh` 下载 GIE CRDs 和 agentgateway CRDs 到本地

---

## 部署顺序

```
Step 1  GIE CRDs               (kubectl apply --server-side)
Step 2  agentgateway CRDs      (kubectl apply --server-side)
Step 3  agentgateway controller (01-agentgateway-controller.yaml)
Step 4  Namespace + Secret     (02-namespace.yaml)
Step 5  Gateway                (03-gateway.yaml)
Step 6  EPP + HTTPRoute + InferencePool  (04-llmd-router.yaml)
Step 7  vLLM model             (05-vllm-model.yaml)
```

---

## Step 1 & 2 — CRDs（直接 apply 文件）

```bash
# GIE CRDs（Gateway API Inference Extension v1.5.0）
kubectl apply --server-side -f /root/deploy/llm-d-gateway/gie-v1.5.0.yaml

# agentgateway 专属 CRDs
kubectl apply --server-side -f /root/deploy/llm-d-gateway/agentgateway-crds/
```

---

## Step 3 — agentgateway controller

文件：`01-agentgateway-controller.yaml`

```yaml
# ── Namespace ────────────────────────────────────────────────────────────────
apiVersion: v1
kind: Namespace
metadata:
  name: agentgateway-system
---
# ── ServiceAccount ───────────────────────────────────────────────────────────
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agentgateway
  namespace: agentgateway-system
  labels:
    agentgateway: agentgateway
    app.kubernetes.io/name: agentgateway
    app.kubernetes.io/instance: agentgateway
    app.kubernetes.io/version: "v1.3.1"
---
# ── ClusterRole ──────────────────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: agentgateway-agentgateway-system
rules:
- apiGroups: [""]
  resources: [configmaps, services]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [""]
  resources: [endpoints, namespaces, nodes, pods]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [events]
  verbs: [create, patch]
- apiGroups: [""]
  resources: [secrets, serviceaccounts]
  verbs: [create, delete, get, list, patch, watch]
- apiGroups: [agentgateway.dev]
  resources: [agentgatewaybackends, agentgatewayparameters, agentgatewaypolicies]
  verbs: [get, list, watch]
- apiGroups: [agentgateway.dev]
  resources: [agentgatewaybackends/status, agentgatewayparameters/status, agentgatewaypolicies/status]
  verbs: [get, patch, update]
- apiGroups: [apiextensions.k8s.io]
  resources: [customresourcedefinitions]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [authentication.k8s.io]
  resources: [tokenreviews]
  verbs: [create]
- apiGroups: [autoscaling]
  resources: [horizontalpodautoscalers]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [coordination.k8s.io]
  resources: [leases]
  verbs: [create, get, update]
- apiGroups: [discovery.k8s.io]
  resources: [endpointslices]
  verbs: [get, list, watch]
- apiGroups: [gateway.networking.k8s.io]
  resources: [backendtlspolicies, gateways, grpcroutes, httproutes, referencegrants, tcproutes, tlsroutes]
  verbs: [get, list, watch]
- apiGroups: [gateway.networking.k8s.io]
  resources: [backendtlspolicies/status, gatewayclasses/status, gateways/status, grpcroutes/status, httproutes/status, tcproutes/status, tlsroutes/status]
  verbs: [patch, update]
- apiGroups: [gateway.networking.k8s.io]
  resources: [gatewayclasses]
  verbs: [create, get, list, patch, update, watch]
- apiGroups: [policy]
  resources: [poddisruptionbudgets]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [inference.networking.k8s.io]
  resources: [inferencepools]
  verbs: [get, watch, list]
- apiGroups: [inference.networking.k8s.io]
  resources: [inferencepools/status]
  verbs: [patch, update]
---
# ── ClusterRoleBinding ───────────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agentgateway-role-agentgateway-system
subjects:
- kind: ServiceAccount
  name: agentgateway
  namespace: agentgateway-system
roleRef:
  kind: ClusterRole
  name: agentgateway-agentgateway-system
  apiGroup: rbac.authorization.k8s.io
---
# ── Service（xDS gRPC + health + metrics）────────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: agentgateway
  namespace: agentgateway-system
  labels:
    agentgateway: agentgateway
    app.kubernetes.io/name: agentgateway
    app.kubernetes.io/instance: agentgateway
spec:
  type: ClusterIP
  selector:
    agentgateway: agentgateway
    app.kubernetes.io/name: agentgateway
    app.kubernetes.io/instance: agentgateway
  ports:
  - name: grpc-xds-agw
    port: 9978
    protocol: TCP
  - name: health
    port: 9093
    protocol: TCP
  - name: metrics
    port: 9092
    protocol: TCP
---
# ── GatewayClass ─────────────────────────────────────────────────────────────
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: agentgateway
spec:
  controllerName: agentgateway.dev/agentgateway
  description: Specialized class for agentgateway.
---
# ── Deployment（controller）──────────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentgateway
  namespace: agentgateway-system
  labels:
    agentgateway: agentgateway
    app.kubernetes.io/name: agentgateway
    app.kubernetes.io/instance: agentgateway
    app.kubernetes.io/version: "v1.3.1"
spec:
  replicas: 1
  selector:
    matchLabels:
      agentgateway: agentgateway
      app.kubernetes.io/name: agentgateway
      app.kubernetes.io/instance: agentgateway
  template:
    metadata:
      annotations:
        prometheus.io/path: /metrics
        prometheus.io/port: "9092"
        prometheus.io/scrape: "true"
      labels:
        agentgateway: agentgateway
        app.kubernetes.io/name: agentgateway
        app.kubernetes.io/instance: agentgateway
    spec:
      serviceAccountName: agentgateway
      containers:
      - name: controller
        image: cr.agentgateway.dev/controller:v1.3.1
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          capabilities:
            drop: [ALL]
        ports:
        - containerPort: 9978
          name: grpc-xds-agw
        - containerPort: 9093
          name: health
        - containerPort: 9092
          name: metrics
        env:
        - name: GOMEMLIMIT
          valueFrom:
            resourceFieldRef:
              resource: limits.memory
              divisor: "1"
        - name: GOMAXPROCS
          valueFrom:
            resourceFieldRef:
              resource: limits.cpu
              divisor: "1"
        - name: AGW_PROXY_IMAGE_REGISTRY
          value: cr.agentgateway.dev
        - name: AGW_PROXY_IMAGE_REPOSITORY
          value: agentgateway
        - name: AGW_LOG_LEVEL
          value: info
        - name: AGW_XDS_SERVICE_NAME
          value: agentgateway
        - name: AGW_AGENTGATEWAY_XDS_SERVICE_PORT
          value: "9978"
        - name: AGW_DISCOVERY_NAMESPACE_SELECTORS
          value: "[]"
        - name: AGW_ENABLE_INFER_EXT
          value: "true"
        - name: AGW_XDS_MODE
          value: tls
        - name: AGW_GATEWAY_CLASS_PARAMETERS_REFS
          value: "{}"
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /readyz
            port: 9093
          initialDelaySeconds: 1
          periodSeconds: 10
        startupProbe:
          httpGet:
            path: /readyz
            port: 9093
          initialDelaySeconds: 0
          periodSeconds: 1
          failureThreshold: 120
```

```bash
kubectl apply -f 01-agentgateway-controller.yaml
# 等待 controller 就绪
kubectl rollout status deployment/agentgateway -n agentgateway-system --timeout=120s
```

---

## Step 4 — Namespace + HF Token Secret

文件：`02-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm-d-gateway
---
apiVersion: v1
kind: Secret
metadata:
  name: llm-d-hf-token
  namespace: llm-d-gateway
type: Opaque
stringData:
  HF_TOKEN: "dummy"    # 离线环境填 dummy；在线环境填真实 HuggingFace token
```

```bash
kubectl apply -f 02-namespace.yaml
```

---

## Step 5 — Gateway

文件：`03-gateway.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-d-inference-gateway
  namespace: llm-d-gateway
spec:
  gatewayClassName: agentgateway
  listeners:
  - name: default
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

```bash
kubectl apply -f 03-gateway.yaml
# agentgateway controller 检测到 Gateway 对象后，自动在 llm-d-gateway namespace 创建：
#   - Deployment/llm-d-inference-gateway（proxy 数据面）
#   - Service/llm-d-inference-gateway（LoadBalancer，对外暴露 NodePort）
# 等待 Gateway Programmed
kubectl wait gateway/llm-d-inference-gateway -n llm-d-gateway \
  --for=jsonpath='{.status.conditions[?(@.type=="Programmed")].status}=True' \
  --timeout=60s
```

---

## Step 6 — EPP + HTTPRoute + InferencePool

文件：`04-llmd-router.yaml`

```yaml
# ── ServiceAccount ───────────────────────────────────────────────────────────
apiVersion: v1
kind: ServiceAccount
metadata:
  name: quickstart-epp
  namespace: llm-d-gateway
---
# ── Role：EPP 读取 pods 权限 ──────────────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: quickstart-epp-sa
  namespace: llm-d-gateway
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get, watch, list]
---
# ── Role：EPP 读取 InferencePool 权限 ─────────────────────────────────────────
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: quickstart-epp-non-sa
  namespace: llm-d-gateway
rules:
- apiGroups: [inference.networking.x-k8s.io]
  resources: [inferenceobjectives, inferencemodelrewrites]
  verbs: [get, watch, list]
- apiGroups: [llm-d.ai]
  resources: [inferenceobjectives, inferencemodelrewrites]
  verbs: [get, watch, list]
- apiGroups: [inference.networking.k8s.io]
  resources: [inferencepools]
  verbs: [get, watch, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: quickstart-epp-sa
  namespace: llm-d-gateway
subjects:
- kind: ServiceAccount
  name: quickstart-epp
  namespace: llm-d-gateway
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: quickstart-epp-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: quickstart-epp-non-sa
  namespace: llm-d-gateway
subjects:
- kind: ServiceAccount
  name: quickstart-epp
  namespace: llm-d-gateway
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: quickstart-epp-non-sa
---
# ── ConfigMap：EPP 调度策略插件配置 ───────────────────────────────────────────
apiVersion: v1
kind: ConfigMap
metadata:
  name: quickstart-epp
  namespace: llm-d-gateway
data:
  # optimized-baseline：综合 KV Cache、前缀缓存、队列长度的加权评分
  optimized-baseline-plugins.yaml: |
    apiVersion: llm-d.ai/v1alpha1
    kind: EndpointPickerConfig
    plugins:
    - type: queue-scorer
    - type: kv-cache-utilization-scorer
    - type: prefix-cache-scorer
    - type: no-hit-lru-scorer
    schedulingProfiles:
    - name: default
      plugins:
      - pluginRef: queue-scorer
        weight: 2
      - pluginRef: kv-cache-utilization-scorer
        weight: 2
      - pluginRef: prefix-cache-scorer
        weight: 3
      - pluginRef: no-hit-lru-scorer
        weight: 2
  # payload-agnostic：不解析请求体，按活跃请求数 + session 亲和性路由
  payload-agnostic.yaml: |
    apiVersion: llm-d.ai/v1alpha1
    kind: EndpointPickerConfig
    plugins:
    - type: passthrough-parser
    - type: active-request-scorer
    - type: session-affinity-scorer
    requestHandler:
      parsers:
      - pluginRef: passthrough-parser
    schedulingProfiles:
    - name: default
      plugins:
      - pluginRef: active-request-scorer
        weight: 1
      - pluginRef: session-affinity-scorer
        weight: 1
---
# ── Service：EPP ──────────────────────────────────────────────────────────────
apiVersion: v1
kind: Service
metadata:
  name: quickstart-epp
  namespace: llm-d-gateway
spec:
  type: ClusterIP
  selector:
    llm-d-router-gateway: quickstart-epp
  ports:
  - name: grpc-ext-proc
    port: 9002
    protocol: TCP
  - name: http-metrics
    port: 9090
    protocol: TCP
  - name: http
    port: 80
    targetPort: 8081
    protocol: TCP
---
# ── Deployment：EPP ───────────────────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quickstart-epp
  namespace: llm-d-gateway
  labels:
    app.kubernetes.io/name: quickstart-epp
    app.kubernetes.io/version: "v0.9.0"
spec:
  replicas: 1
  strategy:
    type: Recreate    # EPP 有状态（前缀缓存统计），建议单副本 Recreate
  selector:
    matchLabels:
      llm-d-router-gateway: quickstart-epp
  template:
    metadata:
      labels:
        llm-d-router-gateway: quickstart-epp
    spec:
      serviceAccountName: quickstart-epp
      terminationGracePeriodSeconds: 130
      containers:
      - name: epp
        image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
        imagePullPolicy: IfNotPresent
        args:
        - --pool-name
        - quickstart
        - --pool-namespace
        - llm-d-gateway
        - --pool-group
        - inference.networking.k8s.io
        - --zap-encoder
        - json
        - --config-file
        - /config/optimized-baseline-plugins.yaml
        - --grpc-health-port
        - "9003"
        - "--v=2"
        - --tracing=false
        ports:
        - name: grpc
          containerPort: 9002
        - name: grpc-health
          containerPort: 9003
        - name: metrics
          containerPort: 9090
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        resources:
          requests:
            cpu: "4"
            memory: 8Gi
          limits:
            memory: 16Gi
        livenessProbe:
          grpc:
            port: 9003
            service: inference-extension
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          grpc:
            port: 9003
            service: inference-extension
          periodSeconds: 2
        volumeMounts:
        - name: plugins-config-volume
          mountPath: /config
      volumes:
      - name: plugins-config-volume
        configMap:
          name: quickstart-epp
---
# ── InferencePool ─────────────────────────────────────────────────────────────
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: quickstart
  namespace: llm-d-gateway
spec:
  appProtocol: http
  selector:
    matchLabels:
      llm-d.ai/guide: optimized-baseline    # 选中带此 label 的 vLLM pod
  targetPorts:
  - number: 8000
  endpointPickerRef:
    kind: Service
    name: quickstart-epp
    port:
      number: 9002
    failureMode: FailOpen    # EPP 故障时退化为随机转发
---
# ── HTTPRoute ────────────────────────────────────────────────────────────────
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: quickstart
  namespace: llm-d-gateway
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: llm-d-inference-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: quickstart
      weight: 1
    timeouts:
      request: 300s    # 推理超时 5 分钟
```

```bash
kubectl apply -f 04-llmd-router.yaml
```

---

## Step 7 — vLLM 模型服务

文件：`05-vllm-model.yaml`

> 将 `MODEL_NAME`、`MODEL_PATH`、`MODEL_CACHE` 替换为实际值后 apply。

```yaml
# 示例：Qwen2.5-7B-Instruct，模型文件位于 /root/models
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen25-7b-instruct
  namespace: llm-d-gateway
  labels:
    llm-d.ai/model: qwen25-7b-instruct
    llm-d.ai/guide: optimized-baseline    # 必须带此 label，InferencePool 才能选中
spec:
  replicas: 1
  selector:
    matchLabels:
      llm-d.ai/model: qwen25-7b-instruct
      llm-d.ai/guide: optimized-baseline
  template:
    metadata:
      labels:
        llm-d.ai/model: qwen25-7b-instruct
        llm-d.ai/guide: optimized-baseline
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
        - /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/<snapshot-hash>
        - --served-model-name=qwen25-7b-instruct
        - --host=0.0.0.0
        - --port=8000
        - --dtype=half
        - --max-model-len=8192
        - --gpu-memory-utilization=0.85
        - --enable-prefix-caching
        env:
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        ports:
        - name: http
          containerPort: 8000
        resources:
          requests:
            nvidia.com/gpu: "1"
            memory: 16Gi
          limits:
            nvidia.com/gpu: "1"
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 15
          failureThreshold: 40
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 30
        volumeMounts:
        - name: model-cache
          mountPath: /root/models
      volumes:
      - name: model-cache
        hostPath:
          path: /root/models      # 宿主机模型目录
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: qwen25-7b-instruct
  namespace: llm-d-gateway
spec:
  type: ClusterIP
  selector:
    llm-d.ai/model: qwen25-7b-instruct
    llm-d.ai/guide: optimized-baseline
  ports:
  - name: http
    port: 8000
    targetPort: 8000
```

> **注意**：`args` 中的模型路径需指向具体 snapshot 目录。可用以下命令查询：
> ```bash
> ls /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/
> ```

```bash
kubectl apply -f 05-vllm-model.yaml
kubectl rollout status deployment/qwen25-7b-instruct -n llm-d-gateway --timeout=600s
```

---

## 验证

```bash
# 查看所有 pod 状态
kubectl get pods -n agentgateway-system
kubectl get pods -n llm-d-gateway

# 查看 Gateway / HTTPRoute / InferencePool 状态
kubectl get gateway,httproute,inferencepool -n llm-d-gateway

# 获取 NodePort
NODE_PORT=$(kubectl get svc llm-d-inference-gateway -n llm-d-gateway \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# 推理测试
curl http://${NODE_IP}:${NODE_PORT}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

---

## 清理

```bash
kubectl delete -f 05-vllm-model.yaml
kubectl delete -f 04-llmd-router.yaml
kubectl delete -f 03-gateway.yaml
kubectl delete -f 02-namespace.yaml
kubectl delete -f 01-agentgateway-controller.yaml
```
