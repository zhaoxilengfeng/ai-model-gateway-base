# 多模型单入口路由指南

本文记录在同一个 agentgateway 入口下支持多个模型（不同 InferencePool）的配置方案。

---

## 架构

```
客户端
  │  标准 OpenAI 请求（只设置 model 字段）
  ▼
http://116.198.67.18:31273（单一入口，llm-d-inference-gateway NodePort）
  │
  ▼
agentgateway proxy
  │  AgentgatewayPolicy (PreRouting)：读取 request.body.model，写入内部 header
  ├─ model=qwen25-7b-instruct → header: X-Gateway-Base-Model-Name: qwen25-7b-instruct
  └─ model=glm-4-9b           → header: X-Gateway-Base-Model-Name: glm-4-9b
  │
  ▼
HTTPRoute (llm-model-route)：按 header 分流
  ├─ X-Gateway-Base-Model-Name: qwen25-7b-instruct → InferencePool/precise-prefix-cache-routing
  └─ X-Gateway-Base-Model-Name: glm-4-9b           → InferencePool/glm4-9b-pool
  │
  ▼
各自的 EPP → 对应 vLLM/sglang pod
```

---

## 关键原则

### 每个模型必须有独立的 guide label

InferencePool 通过 `llm-d.ai/guide` label 选择 pod。不同模型的 Deployment 和 InferencePool
**必须使用不同的 guide label**，否则两个池会选中对方的 pod，导致路由混乱。

| 模型 | guide label |
|------|------------|
| qwen25-7b-instruct | `precise-prefix-cache-routing` |
| glm-4-9b | `glm4-9b-pool` |

**注意**：Deployment 的 `spec.selector` 是 immutable，修改 guide label 必须**删除重建** Deployment，不能 patch。

### agentgateway 的 model-based routing 机制

agentgateway v1.3.1 原生支持按请求体 `model` 字段路由，**客户端无需改动**。

实现方式：
1. **PreRouting Policy**：CEL 表达式读取 `json(request.body).model`，映射写入内部 header
2. **HTTPRoute**：按 header 值路由到对应 InferencePool

---

## 配置文件

### 1. AgentgatewayPolicy（model → header 映射）

文件：`policy-model-routing.yaml`

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: model-routing-policy
  namespace: llm-d-precise-prefix-gw
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: llm-d-inference-gateway
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
          - name: X-Gateway-Base-Model-Name
            value: |
              {
                "qwen25-7b-instruct": "qwen25-7b-instruct",
                "glm-4-9b": "glm-4-9b"
              }[string(json(request.body).model)]
```

**新增模型时**：在映射表里追加一行，如 `"new-model": "new-model"`，然后在 HTTPRoute 里追加对应规则。

### 2. HTTPRoute（header → InferencePool）

文件：`httproute-model-routing.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-model-route
  namespace: llm-d-precise-prefix-gw
spec:
  parentRefs:
    - kind: Gateway
      name: llm-d-inference-gateway
  rules:
    - matches:
        - path: {type: PathPrefix, value: /v1/}
          headers:
            - {type: Exact, name: X-Gateway-Base-Model-Name, value: glm-4-9b}
      backendRefs:
        - {group: inference.networking.k8s.io, kind: InferencePool, name: glm4-9b-pool}
    - matches:
        - path: {type: PathPrefix, value: /v1/}
          headers:
            - {type: Exact, name: X-Gateway-Base-Model-Name, value: qwen25-7b-instruct}
      backendRefs:
        - {group: inference.networking.k8s.io, kind: InferencePool, name: precise-prefix-cache-routing}
    # 默认回退 → qwen
    - matches:
        - path: {type: PathPrefix, value: /v1/}
      backendRefs:
        - {group: inference.networking.k8s.io, kind: InferencePool, name: precise-prefix-cache-routing}
```

---

## 新增模型的完整步骤

1. **下载模型**到 GPU 节点
2. **创建 pool.env**：`pools/<model-name>/pool.env`，设置独立的 `GUIDE_NAME`
3. **安装推理池**：`bash install-pool.sh --pool <model-name>`
   - render 服务自动创建
   - EPP + InferencePool + Gateway 自动创建
4. **部署模型 pod**：`bash models/start-<model-name>.sh`
   - Deployment 的 `llm-d.ai/guide` label 必须与 pool.env 的 `GUIDE_NAME` 一致
5. **更新路由配置**：
   - `policy-model-routing.yaml`：追加模型名映射
   - `httproute-model-routing.yaml`：追加路由规则
   - `kubectl apply -f policy-model-routing.yaml -f httproute-model-routing.yaml`

---

## 当前模型清单

| 模型 | guide label | InferencePool | 访问地址 |
|------|------------|---------------|---------|
| qwen25-7b-instruct | precise-prefix-cache-routing | precise-prefix-cache-routing | http://116.198.67.18:31273 |
| glm-4-9b | glm4-9b-pool | glm4-9b-pool | http://116.198.67.18:31273（同一入口）|

---

## 弹性扩缩容

每个 InferencePool 各自独立，可以分别配置 KEDA/HPA：

```bash
# 示例：给 qwen 池配置基于 GPU 利用率的自动扩缩
kubectl apply -f scaledobject-qwen.yaml -n llm-d-precise-prefix-gw

# GLM 池独立扩缩，互不影响
kubectl apply -f scaledobject-glm.yaml -n llm-d-precise-prefix-gw
```

两个池的 pod 数量、资源配额、扩缩策略完全独立，是最佳的隔离边界。

---

## 验证命令

```bash
# 验证两个模型通过单入口正常响应
for model in qwen25-7b-instruct glm-4-9b; do
  curl -s http://116.198.67.18:31273/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('$model:', d['choices'][0]['message']['content'])"
done
```
