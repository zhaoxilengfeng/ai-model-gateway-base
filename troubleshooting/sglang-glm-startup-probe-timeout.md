# sglang GLM-5.2-FP8 启动失败：startupProbe 超时导致 CrashLoop

## 问题现象

部署 GLM-5.2-FP8（sglang）后，pod 一直处于 `0/1 Running`，反复重启：

```
NAME                          READY   STATUS    RESTARTS
glm-5-2-fp8-xxx               0/1     Running   1 (10m ago)
```

`kubectl describe pod` 中出现：

```
Warning  Unhealthy  kubelet  Startup probe failed: context deadline exceeded (Client.Timeout exceeded while awaiting headers)
Normal   Killing    kubelet  Container sglang failed startup probe, will be restarted
```

直接访问 agentgateway 报错：

```json
{"error": {"message": "The model `glm-5-2-fp8` does not exist.", "code": 404}}
```

## 根本原因

sglang 启动 GLM-5.2-FP8 时需要经历两个耗时阶段：

1. **CUDA graph capture**（约 5 分钟）：在此阶段 `/health` 接口存在但响应极慢（超过 1s）
2. **DeepGEMM JIT Pre-Compile**（首次约 10-20 分钟，后续有缓存约 1-2 分钟）：每次 CUDA graph capture 触发一个新矩阵形状时都会进入此阶段，`/health` 返回 503

`deploy-glm-sglang.sh` 中三个 probe 均未设置 `timeoutSeconds`，默认值为 **1 秒**，导致：

- CUDA graph capture 期间 `/health` 响应超过 1s → probe 超时失败
- 累积失败次数耗尽 `failureThreshold`（startupProbe = 60 次 × 20s = 1200s）→ kubelet 强制重启容器
- 重启后重新走一遍 CUDA graph + DeepGEMM，形成循环

## 排查步骤

```bash
# 1. 确认 probe 失败原因
kubectl describe pod <pod-name> -n llm-d-precise-prefix-gw | grep -A3 'Unhealthy\|Killing'

# 2. 查看启动进度（确认是否卡在 CUDA graph 或 DeepGEMM）
kubectl logs <pod-name> -n llm-d-precise-prefix-gw | grep -E 'CUDA graph|DeepGEMM|startup complete|ready to roll|503|200'

# 3. 直接测试 pod IP，确认服务本身是否正常（绕过 probe 判断）
POD_IP=$(kubectl get pod <pod-name> -n llm-d-precise-prefix-gw -o jsonpath='{.status.podIP}')
curl http://${POD_IP}:8000/health
curl http://${POD_IP}:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-5-2-fp8","messages":[{"role":"user","content":"你好"}],"max_tokens":50}'
```

## 解决方案

在 `deploy-glm-sglang.sh` 的三个 probe 中加入 `timeoutSeconds: 30`：

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 8000
  timeoutSeconds: 30        # 新增：允许 /health 最多 30s 响应
  initialDelaySeconds: 60
  periodSeconds: 20
  failureThreshold: 60
readinessProbe:
  httpGet:
    path: /health
    port: 8000
  timeoutSeconds: 30        # 新增
  initialDelaySeconds: 120
  periodSeconds: 15
  failureThreshold: 10
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  timeoutSeconds: 30        # 新增
  initialDelaySeconds: 180
  periodSeconds: 30
```

**注意**：GLM-5.2-FP8 占用整机 8 张 GPU，Deployment strategy 必须设为 `Recreate`，否则滚动更新时新 pod 因 GPU 不足而 Pending：

```yaml
spec:
  strategy:
    type: Recreate
```

## 附：DeepGEMM 预编译加速

首次启动耗时较长的根因是 DeepGEMM JIT 需要现场编译所有矩阵形状（约 10-20 分钟）。后续重启已有缓存（`~/.cache/deep_gemm`），仅需 1-2 分钟。

如需彻底消除此开销，可在容器启动前预先运行：

```bash
python3 -m sglang.compile_deep_gemm \
  --model /home/data/model/GLM-5.2-FP8 \
  --tp 8 \
  --trust-remote-code
```

## 时间线

| 时间 | 事件 |
|---|---|
| 2026-07-16 | 部署 GLM-5.2-FP8，因 qwen25-7b-instruct 占满 8 张 GPU 导致 Pending |
| 2026-07-16 | 缩减 qwen 至 0 副本后 GLM pod 调度成功，但 startupProbe 超时循环重启 |
| 2026-07-16 | 确认根因为 timeoutSeconds 默认 1s，CUDA graph 期间响应慢导致误判 |
| 2026-07-16 | patch deployment 将三个 probe 的 timeoutSeconds 改为 30s，同时改 strategy 为 Recreate |
| 2026-07-16 | pod 正常启动，`http://116.198.67.18:31273` 可访问 glm-5-2-fp8 |
