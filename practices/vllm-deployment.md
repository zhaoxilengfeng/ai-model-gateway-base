# vLLM 部署配置要点

## 版本与驱动要求

| vLLM 版本 | 最低 NVIDIA 驱动 | CUDA 版本 | 备注 |
|---|---|---|---|
| v0.23.0 | 580 | 13.0 | 低于 580 报 Error 804（forward compatibility 失败）|

驱动版本检查：

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

---

## 基础启动参数

```bash
vllm serve <model-path> \
  --served-model-name <name>     # 对外暴露的模型名，需与 EPP 配置一致
  --host 0.0.0.0 \
  --port 8000 \
  --dtype half \                 # 半精度，节省显存
  --max-model-len 8192 \         # 最大序列长度，根据显存调整
  --gpu-memory-utilization 0.85 \
  --enable-prefix-caching        # 开启前缀缓存（所有模式都建议开启）
```

---

## 精准前缀路由额外参数

在 optimized-baseline 基础上需要额外加：

```bash
  --block-size=64 \              # 必须与 EPP precise-prefix-cache-producer blockSize=64 一致
  --kv-events-config '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@$(POD_IP):8000@<served-model-name>"}'
```

并暴露 ZMQ 端口：

```yaml
ports:
- name: http
  containerPort: 8000
- name: kv-events
  containerPort: 5556
  protocol: TCP
```

**关键约束**：
- `block-size` 必须与 EPP 的 `tokenProcessorConfig.blockSize` 完全一致，否则哈希不匹配，精准路由失效
- topic 中的模型名必须与 `--served-model-name` 一致，EPP 用它做多模型索引隔离
- `POD_IP` 通过 K8s downward API 注入，不能硬编码

---

## 离线部署配置

模型文件从 hostPath 本地加载，禁止联网：

```yaml
env:
- name: HF_HUB_OFFLINE
  value: "1"
- name: TRANSFORMERS_OFFLINE
  value: "1"
- name: DO_NOT_TRACK
  value: "1"
volumeMounts:
- name: model-cache
  mountPath: /root/models
volumes:
- name: model-cache
  hostPath:
    path: /root/models
    type: DirectoryOrCreate
```

模型路径指向具体的 snapshot 目录（不是 hub 根目录）：

```bash
# 查询 snapshot hash
ls /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/

# args 中使用完整路径
args:
- /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/<hash>
```

---

## 多副本部署建议

### 精准前缀路由

- **最少 2 个 pod**：单 pod 下路由选择无意义，精准路由效果体现不出来
- 每个 GPU 节点跑一个 pod，不同 pod 的 KV cache 相互独立，EPP 才能做有意义的路由决策
- **扩容新 pod 无需重启 EPP**：EPP 的 pod_reconciler 监听 K8s pod ADD 事件，新 pod Ready 后自动发现并建立 ZMQ 订阅
- **pod 重启（DELETE+ADD）无需重启 EPP**：EPP 收到 ADD 事件后自动重建 ZMQ 连接
- **rollout restart 视时序而定**：若精准路由持续失效（verify 脚本 Check 3 < 60%），重启 EPP 即可恢复

```bash
# pod 重启后（IP 变化），需手动重启 EPP
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
```

### 负载感知路由

- 副本数根据 QPS 和 GPU 利用率决定，无特殊限制

---

## 探针配置

vLLM 模型加载时间较长，建议 startupProbe 留足时间：

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 30
  periodSeconds: 15
  failureThreshold: 40        # 最多等 30 + 15×40 = 630s ≈ 10 分钟

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
```

---

## 资源配置参考

| 模型规模 | GPU | 显存 | 建议 max-model-len |
|---|---|---|---|
| 7B（half） | 1× A100 80G | 约 16GB | 32768 |
| 7B（half） | 1× V100 32G | 约 16GB | 8192 |
| 32B（half） | 2× A100 80G | 约 64GB | 32768 |

```yaml
resources:
  requests:
    nvidia.com/gpu: "1"
    memory: "16Gi"
  limits:
    nvidia.com/gpu: "1"
```

---

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `Error 804: forward compatibility` | 驱动版本 < 580 | 升级驱动到 580+ |
| pod 启动超时 | startupProbe failureThreshold 太小 | 增大到 40+ |
| KV cache 命中率低 | `--enable-prefix-caching` 未开启 | 加上该参数 |
| 精准路由 score 0 | pod 重启后 EPP ZMQ 断开 | 重启 EPP |
| ZMQ 事件不通 | `--block-size` 与 EPP 不一致 | 统一为 64 |
