# AIBrix 推理模型部署指南

在 AIBrix 上部署一个推理模型需要三步：创建 Deployment、创建 Service、等待 controller 自动创建 HTTPRoute。

## 核心机制

AIBrix controller-manager 监听带有以下两个 label 的 Deployment，自动在 `aibrix-system` 创建对应的 HTTPRoute：

```
model.aibrix.ai/name: <模型名>   # 路由匹配 key，请求的 model 字段必须与此一致
model.aibrix.ai/port: "8000"     # 推理服务监听端口
```

**Service 不会自动创建，必须手动部署。**

---

## 部署步骤

### 1. 创建 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen25-7b-instruct-v2
  namespace: default
  labels:
    model.aibrix.ai/name: qwen25-7b-instruct-v2
    model.aibrix.ai/port: "8000"
spec:
  replicas: 1
  selector:
    matchLabels:
      model.aibrix.ai/name: qwen25-7b-instruct-v2
      model.aibrix.ai/port: "8000"
  template:
    metadata:
      labels:
        model.aibrix.ai/name: qwen25-7b-instruct-v2
        model.aibrix.ai/port: "8000"
    spec:
      containers:
      - name: vllm-openai
        image: vllm/vllm-openai:v0.6.6.post1
        imagePullPolicy: IfNotPresent
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
        - --model
        - Qwen/Qwen2.5-7B-Instruct
        - --served-model-name
        - qwen25-7b-instruct-v2   # 必须与 label model.aibrix.ai/name 一致
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
          failureThreshold: 360   # 最长等待 360*10=3600s 模型加载
        volumeMounts:
        - mountPath: /models
          name: model-cache
      volumes:
      - name: model-cache
        hostPath:
          path: /root/models
          type: DirectoryOrCreate
```

### 2. 创建 Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: qwen25-7b-instruct-v2
  namespace: default
spec:
  selector:
    model.aibrix.ai/name: qwen25-7b-instruct-v2
    model.aibrix.ai/port: "8000"
  ports:
  - port: 8000
    targetPort: 8000
```

### 3. 验证 HTTPRoute 自动创建

```bash
# controller-manager 检测到 Deployment 后自动创建，通常几秒内完成
kubectl get httproute -n aibrix-system qwen25-7b-instruct-v2-router
```

---

## 验证请求

```bash
curl http://10.0.0.2:32226/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-7b-instruct-v2",
    "messages": [{"role": "user", "content": "你好"}],
    "max_tokens": 50
  }'
```

---

## 删除模型

```bash
kubectl delete deployment qwen25-7b-instruct-v2 -n default
kubectl delete service qwen25-7b-instruct-v2 -n default
# HTTPRoute 由 controller 自动清理
```

---

## 注意事项

| 项目 | 说明 |
|------|------|
| label 必须一致 | Deployment label、Pod label、`--served-model-name`、请求的 `model` 字段四者必须完全一致 |
| Service 手动创建 | controller 只管 HTTPRoute，不创建 Service |
| 模型文件缓存 | hostPath `/root/models` 挂载，首次启动会从 HF 下载，之后复用缓存 |
| GPU 资源 | 每个 Pod 占用 1 块 GPU，集群当前共 2 块（host-000-003/004 各 1 块） |
| startupProbe | `failureThreshold: 360`，允许模型加载最长 1 小时，不要调小 |
