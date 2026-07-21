# 部署问题排查记录

记录 `install-pool.sh` + `deploy-model.sh` 部署过程中遇到的问题、根因和修复方法。

---

## 问题 1：访问端口 31273 失败（Connection refused）

**现象：**
```
curl: (7) Failed to connect to 116.198.67.18 port 31273
```

**根因：**  
31273 是旧文档/旧部署遗留的端口号。每次运行 `install-pool.sh` 后，agentgateway 会为每个 Gateway 分配新的 NodePort，端口号不固定。

**查询实际端口：**
```bash
kubectl get svc -n llm-d-precise-prefix-gw | grep gateway
```

**当前实际端口：**

| 模型 | Gateway Service | NodePort | 访问地址 |
|------|----------------|---------|---------|
| qwen25-7b-instruct | `precise-prefix-cache-routing-gateway` | 31820 | `http://116.198.67.18:31820` |
| glm-4-9b | `glm4-9b-pool-gateway` | 31161 | `http://116.198.67.18:31161` |

> NodePort 会随重新部署变化，访问前先用 `kubectl get svc` 确认。

---

## 问题 2：render pod 全部 CrashLoopBackOff（空参数）

**现象：**
```
vllm: error: unrecognized arguments:
```

**根因：**  
`install-pool.sh` 中 render 的 args 包含 `"${TRUST_REMOTE_CODE:-}"`，当 pool.env 未设置 `TRUST_REMOTE_CODE` 时展开为空字符串 `""`，作为一个空参数传给 vllm，导致启动失败。

**修复（commit 27058ce）：**  
移除空参数行，改为条件注入：仅当 `TRUST_REMOTE_CODE` 有值时才追加该 arg。

**运维操作（已执行）：**
```bash
# 重新 apply 两个 render deployment（去掉空参数）
kubectl patch deployment precise-prefix-cache-routing-render \
  -n llm-d-precise-prefix-gw \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args",
        "value":["<model-path>","--port=8000","--served-model-name=<served-model>"]}]'
```

---

## 问题 3：glm render CrashLoopBackOff（模型路径解析失败）

**现象：**
```
huggingface_hub.errors.HFValidationError: Repo id must be in the form 'repo_name' or 'namespace/repo_name':
'/home/data/model/glm-4-9b-chat'.
```

或

```
pydantic_core._pydantic_core.ValidationError: Invalid repository ID or local directory:
'/root/models/glm-4-9b-chat'.
```

**根因：**  
`vllm launch render` 把第一个位置参数作为模型路径，但对于非 HuggingFace hub 格式的本地路径（不含 `models--` 或 hub snapshot 结构），vllm 会尝试当作 HuggingFace repo id 下载，失败报错。

`pool.env` 里 `RENDER_MODEL_PATH` 原来设置的是宿主机路径 `/home/data/model/glm-4-9b-chat`，但 render 容器的 `mountPath` 是 `/root/models`，容器内实际路径应为 `/root/models/glm-4-9b-chat`。

**修复（commit ea91ea8）：**  
`pools/glm4-9b/pool.env` 中 `RENDER_MODEL_PATH` 改为容器内路径：
```bash
RENDER_MODEL_PATH="/root/models/glm-4-9b-chat"
```

---

## 问题 4：glm render 在 master01 上启动失败（模型文件缺失）

**现象：**  
render pod 调度到 master01 时 CrashLoopBackOff，调度到 h200-12-3 时 Running。

**根因：**  
`install-pool.sh` 的 render Deployment 没有 `nodeSelector`，pod 随机调度到 master01 或 h200-12-3。  
glm-4-9b-chat 模型文件（18G）**只存在于 h200-12-3**，master01 上 `/home/data/model/glm-4-9b-chat` 是空目录。  
render 使用 CPU 镜像不需要 GPU，可以跑在任意节点，但前提是节点上有模型文件。

**确认方式：**
```bash
# 查看 render pod 被调度到哪个节点
kubectl get pods -n llm-d-precise-prefix-gw -l app.kubernetes.io/component=vllm-render -o wide

# GPU 节点上确认模型存在
ssh root@11.194.12.3 "ls /home/data/model/glm-4-9b-chat/"

# master01 上确认模型缺失
ls /home/data/model/glm-4-9b-chat/
```

**修复：** 将模型文件从 h200-12-3 同步到 master01：
```bash
rsync -avh --progress \
  root@11.194.12.3:/home/data/model/glm-4-9b-chat/ \
  /home/data/model/glm-4-9b-chat/
```

> 模型大小约 18G，master01 磁盘剩余 171G（`/home/data` 分区），同步约需几分钟。  
> 同步完成后，落在 master01 的 render pod 会在下次重启时自动恢复。

**后续操作：**  
同步完成后，手动重启 render deployment 让 CrashLoop 的 pod 重新拉起：
```bash
kubectl rollout restart deployment/glm4-9b-pool-render -n llm-d-precise-prefix-gw
```

---

## 问题 5：GPU 资源超配导致模型 pod Pending

**现象：**
```
0/2 nodes are available: 2 Insufficient nvidia.com/gpu.
```

**根因：**  
节点 h200-12-3 共 8 张 GPU，两个模型同时部署时请求数超出：

- `glm-4-9b`：2 副本 × 1 GPU = 2 张
- `qwen25-7b-instruct`：8 副本 × 1 GPU = 8 张（实际只有 6 张可用）

**解决方法：**  
按可用 GPU 数量控制副本数，两个模型 GPU 需求之和不超过 8：

```bash
# glm 占 2 张，qwen 最多 6 张
REPLICAS=6 bash models/start-qwen25-7b-instruct.sh

# 或销毁 glm 让 qwen 独占 8 张
bash models/undeploy-glm-4-9b.sh
REPLICAS=8 bash models/start-qwen25-7b-instruct.sh
```

---

## 经验总结

| 经验 | 说明 |
|------|------|
| 部署前确认 GPU 资源 | `kubectl describe node h200-12-3 \| grep -A5 'Allocated resources'` |
| NodePort 不固定 | 每次部署后用 `kubectl get svc` 确认实际端口 |
| RENDER_MODEL_PATH 用容器内路径 | hostPath 挂载到 `/root/models`，pool.env 里路径要对应容器内路径 |
| 模型文件要在所有可能的调度节点上 | render 无 GPU 需求，会调度到任意节点；确保所有节点上有模型文件，或下载完成后再部署 |
