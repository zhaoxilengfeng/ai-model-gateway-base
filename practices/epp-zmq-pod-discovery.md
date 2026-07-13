# EPP ZMQ 订阅的自动发现与重连机制

## 结论速查

| 操作 | K8s 事件 | EPP 行为 | 是否需要重启 EPP |
|---|---|---|---|
| `kubectl scale` 扩容新 pod | ADD | 自动发现，自动建立 ZMQ 订阅 | ❌ 不需要 |
| `kubectl delete pod`（Deployment 重建）| DELETE + ADD | 旧连接断开；新 pod ADD 时自动重建 | ❌ 不需要 |
| `kubectl rollout restart`（滚动替换）| UPDATE → DELETE + ADD | Connected 后立刻 shutting down，ZMQ 全部断开 | ✅ 需要 |
| 节点故障，pod 漂移 | DELETE + ADD | 同 delete pod，自动恢复 | ❌ 不需要 |
| EPP 先于 vLLM 启动 | 启动时 List 存量 pod | 正常，自动连接 | ❌ 不需要 |

> `rollout restart` 与 `delete pod` 的区别：前者触发 UPDATE 事件（pod name 变、template hash 变），后者触发 DELETE+ADD 事件。EPP 对 UPDATE 的处理逻辑会导致 `shutting down` 后不重建连接。

---

## EPP 与 pod 的对应关系

**EPP 是 InferencePool 级别的，不是 pod 级别的。**

```
InferencePool（1个）
  └── EPP Deployment（1个，可多副本 HA）
        ├── ZMQ SUB → vLLM pod A :5556
        ├── ZMQ SUB → vLLM pod B :5556
        └── ZMQ SUB → vLLM pod C :5556
              ↓
        统一的 block hash 索引
        （key: hash → value: {pod, 命中块数}）
              ↓
        每次请求：查索引 → 选得分最高的 pod
```

EPP 的 active-active HA 模式（`replicas: 2`）下，每个 EPP 副本各自独立订阅所有 vLLM pod 的 ZMQ，各自维护一份完整索引，两个副本都能独立做路由决策，互不依赖。

---

精准前缀路由（precise-prefix-cache-routing）的 EPP 通过 `pod_reconciler` 监听 vLLM pod 的变更事件，动态维护 ZMQ SUB socket 连接池。

每个 vLLM pod 在 `tcp://*:5556` 绑定一个 ZMQ PUB socket，EPP 连接后订阅 `kv@` 前缀的 KV 块事件，构建 block hash → pod 的倒排索引，用于精准前缀命中评分。

---

## 各场景详细说明

### 场景一：扩容新 pod（scale out）✅ 自动

```bash
kubectl scale deployment qwen25-7b-instruct -n llm-d-precise-prefix --replicas=3
```

K8s 触发 pod ADD 事件，EPP `pod_reconciler` 收到后：
1. 注册新 pod 的 IP 和 NamespacedName 映射
2. 自动建立到新 pod `:5556` 的 ZMQ SUB 连接
3. 开始接收新 pod 的 KV 块事件并更新索引

**EPP 日志验证**（新 pod IP 为 10.244.142.240）：
```
Connected subscriber socket  endpoint=tcp://10.244.142.240:5556
```

实测（3 个 pod 场景）：EPP 在新 pod Ready 后几秒内自动连接，无需任何手动干预，精准路由对 3 个 pod 全部生效。

### 场景二：pod 重启（DELETE + ADD，如 kubectl delete pod）✅ 自动

直接删除 pod，Deployment controller 会创建一个全新的 pod（新 name 或同 name 新 IP）。

- DELETE：EPP 清理旧 IP 的 ZMQ subscriber（`shutting down zmq-subscriber`）
- ADD（新 pod Ready）：EPP `pod_reconciler` 收到 ADD 事件，自动建立新 ZMQ 连接

**实测**：删除 pod 后，新 pod Ready，EPP 自动重连，无需手动干预。

### 场景三：滚动替换（kubectl rollout restart）✅ 需要重启 EPP

`rollout restart` 产生新的 pod template hash，Deployment 创建新 ReplicaSet，旧 pod 逐步被新 pod 替换。

**实测日志**（3 个 pod 全部如此）：

```
Connected subscriber socket  tcp://10.244.142.242:5556
shutting down zmq-subscriber
Connected subscriber socket  tcp://10.244.41.185:5556
shutting down zmq-subscriber
Connected subscriber socket  tcp://10.244.142.243:5556
shutting down zmq-subscriber
```

每个新 pod Ready 后 EPP 都是 **Connected → 立刻 shutting down**，最终 ZMQ 全部断开，精准路由失效，退化为负载感知路由（queue + kv-util scorer 仍工作，推理请求不会失败）。

**原因**：rollout restart 期间每个 pod 会先触发 UPDATE 事件（Terminating），EPP 对 UPDATE 事件的处理逻辑导致在连接建立后又触发了 shutdown，EPP v0.9.0 的已知行为。

**修复**：

```bash
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
```

### 场景四：EPP 先于 vLLM 启动 ✅ 自动

EPP 启动时会通过 K8s informer 初始 List 所有已有 pod，对每个 pod 触发 reconcile，建立 ZMQ 连接。因此 EPP 先于 vLLM 启动也没有问题——等 vLLM pod Ready 后，EPP 收到 ADD 事件，自动连接。

> **之前文档有误**：曾记录"EPP 必须在 vLLM pod 之后启动"，实测证明这一说法不正确，已更正。

---

## 运维建议

### 滚动更新 vLLM 时

`kubectl rollout restart` 是滚动更新，旧 pod 会逐一被新 pod 替换（DELETE → ADD）。

- 每个旧 pod 被删除时，EPP 清理对应的 ZMQ subscriber
- 每个新 pod 创建并 Ready 后，EPP 自动建立新的 ZMQ subscriber
- 整个滚动更新过程中，**只有当前被替换的 pod 暂时不在索引中**，其他 pod 正常服务

滚动更新完成后精准路由会自动恢复，但如果更新期间发现 score 0 持续未恢复，执行：

```bash
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
```

### 监控 ZMQ 连接健康

```bash
# 查看 EPP 当前订阅的所有 ZMQ 连接
EPP_POD=$(kubectl get pods -n llm-d-precise-prefix | grep epp | grep Running | head -1 | awk '{print $1}')
kubectl logs $EPP_POD -n llm-d-precise-prefix -c epp | grep "Connected subscriber socket"

# 对比 vLLM pod 数量（应该一一对应）
kubectl get pods -n llm-d-precise-prefix -l "llm-d.ai/model=qwen25-7b-instruct" --no-headers | wc -l

# 快速验证精准路由是否正常
bash /root/ai-model-gateway-base/llm-d/deploy-precise-prefix/verify-precise-prefix.sh
```

---

## 实测数据

| 操作 | 条件 | 结果 |
|---|---|---|
| scale 2→3（新增 host-000-002）| host-000-002 uncordoned，镜像已就绪 | EPP 自动连接 tcp://10.244.142.240:5556，3 pod 精准路由正常（100% 集中）|
| rollout restart vLLM | pod IP 变化 | EPP ZMQ 断开，score 0，需重启 EPP 恢复 |
