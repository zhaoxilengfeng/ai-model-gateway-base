# 精准前缀路由 ZMQ 索引未建立（prefix-cache-scorer 持续 score 0）

## 问题现象

部署 `deploy-precise-prefix` 后，每次推理请求都被路由但精准前缀评分不生效。

通过以下命令查看 EPP 日志可以发现：

```bash
EPP_POD=$(kubectl get pods -n llm-d-precise-prefix | grep epp | grep Running | head -1 | awk '{print $1}')
kubectl logs $EPP_POD -n llm-d-precise-prefix -c epp | grep "PrefixCacheMatchInfo"
```

输出：

```
PrefixCacheMatchInfo not found for endpoint, assigning score 0
```

说明 prefix-cache-scorer 无法获取 KV 块索引，每次都打 0 分，精准前缀路由退化为其他 scorer（queue、kv-util）做决策。

## 排查过程

### 第一步：确认 ZMQ socket 连接

查看 EPP 日志：

```bash
kubectl logs <epp-pod> -n llm-d-precise-prefix -c epp | grep "zmq\|Connected"
```

**发现**：日志中有 `Connected subscriber socket tcp://<pod-ip>:5556`，说明 ZMQ 连接建立成功。

### 第二步：确认 vLLM 是否真的发布 KV 事件

用 pyzmq 直接订阅 vLLM 的 ZMQ socket：

```python
import zmq
ctx = zmq.Context()
sock = ctx.socket(zmq.SUB)
sock.connect('tcp://<vllm-pod-ip>:5556')
sock.setsockopt(zmq.SUBSCRIBE, b'')
frames = sock.recv_multipart()
print(frames[0])  # topic: b'kv@10.x.x.x:8000@qwen25-7b-instruct'
```

**发现**：vLLM 确实在发布 KV 块事件（`BlockStored`），topic 格式正确：`kv@<pod-ip>:8000@<model-name>`，与 EPP 配置的 `topicFilter: "kv@"` 匹配。

### 第三步：检查 token-producer

```bash
# 检查 render service 暴露的模型名
curl http://<render-svc-ip>:8000/v1/models
```

**初始问题（已修复）**：render 启动时模型参数为本地 snapshot 路径（如 `/root/models/hub/.../snapshots/abc123`），render 暴露的模型 id 也是这个路径，但 EPP `token-producer.modelName` 配置的是 `Qwen/Qwen3-32B`，两者不一致，导致 tokenize 请求返回 404。

**修复**：render 加 `--served-model-name=qwen25-7b-instruct`，EPP helm values 中 `modelName` 改为 `qwen25-7b-instruct`。

### 第四步：定位真正根因

token-producer 修复后，`score 0` 依然持续。继续检查 EPP 的 pod-discovery 日志：

```bash
kubectl logs <epp-pod> -c epp | grep "pod_reconcil\|zmq\|shutting"
```

**发现关键日志**：

```
Connected subscriber socket tcp://<new-pod-ip>:5556
shutting down zmq-subscriber
```

EPP 连接新 pod 后立刻关闭了 subscriber，原因是：

- EPP 通过 `pod_reconciler` watch pod 事件（ADD/UPDATE/DELETE）
- 当 vLLM pod 在 EPP **之前**启动时，EPP 启动后不会收到 ADD 事件（pod 已存在），pod-discovery 不知道这个 pod，无法建立 IP → endpoint 的映射
- ZMQ 虽然连接上了，但收到的事件无法关联到已知端点，索引无法建立

### 验证根因

重启 EPP（让它在 vLLM pod 存在的情况下重新做 pod-discovery）：

```bash
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
```

重启后 EPP 通过 List+Watch 获取所有已有 pod，`pod_reconciler` 正常触发，ZMQ 订阅建立，KV 索引开始积累，`score 0` 消失。

## 根本原因

**EPP pod-discovery 的两种场景行为不同**：

| 场景 | K8s 事件 | EPP 行为 |
|---|---|---|
| **扩容新 pod**（scale out）| ADD | ✅ 自动感知，自动建立 ZMQ 订阅，无需重启 EPP |
| **pod 原地重启**（IP 变化，name 不变）| UPDATE | ❌ 检测到 "Pod already exists"，shutdown 旧 IP 的 subscriber，不用新 IP 重建 |

扩容场景 EPP 可以自动处理，不需要重启。只有 **pod 重启导致 IP 变化** 才需要重启 EPP。

## 解决方案

### 临时修复

vLLM pod 重启后，重启 EPP：

```bash
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
```

### 验证是否生效

```bash
bash /root/ai-model-gateway-base/llm-d/deploy-precise-prefix/verify-precise-prefix.sh
```

脚本的 Check 3 会检测以下情况：
- ZMQ subscriber 已关闭（`shutting down zmq-subscriber`）→ 提示重启 EPP
- token-producer 失败（404 model not found）→ 检查模型名一致性
- 持续 score 0 但 ZMQ 正常 → 可能是 EPP 先于 vLLM 启动，重启 EPP

### 永久规避

在 `install.sh` 中，deploy-model.sh 之后加一步重启 EPP：

```bash
# 部署模型后重启 EPP，确保 pod-discovery 感知新 vLLM pod
bash deploy-model.sh
kubectl rollout restart deployment/${GUIDE_NAME}-epp -n ${NAMESPACE}
kubectl rollout status deployment/${GUIDE_NAME}-epp -n ${NAMESPACE} --timeout=60s
```

## 相关配置

| 配置项 | 正确值 | 说明 |
|---|---|---|
| vLLM `--block-size` | `64` | 必须与 EPP `tokenProcessorConfig.blockSize` 一致 |
| vLLM `--kv-events-config` topic | `kv@$(POD_IP):8000@<model>` | EPP `topicFilter: "kv@"` 过滤前缀 |
| vLLM `--served-model-name` | `qwen25-7b-instruct` | 必须与 EPP `token-producer.modelName` 和 render `--served-model-name` 一致 |
| render `--served-model-name` | `qwen25-7b-instruct` | 必须与 EPP `token-producer.modelName` 一致 |
| EPP `token-producer.modelName` | `qwen25-7b-instruct` | 必须与 render 暴露的模型名一致 |

## 时间线

| 时间 | 事件 |
|---|---|
| 2026-07-13 | 发现 score 0 问题，排查 ZMQ 连接正常但 EPP 未收到事件 |
| 2026-07-13 | 确认 vLLM 确实发布 KV 事件，问题在 EPP pod-discovery 启动顺序 |
| 2026-07-13 | 通过重启 EPP 解决，verify 脚本加入检测逻辑 |
