# GLM-4-9B 部署问题记录

**日期**：2026-07-21  
**模型**：GLM-4-9B（glm-4-9b-chat，18GB）  
**框架**：vLLM v0.23.0

---

## 问题 1：模型路径 HFValidationError

### 现象

```
HFValidationError: Repo id must be in the form 'repo_name' or 'namespace/repo_name': 
'/home/data/model/glm-4-9b-chat'. Use `repo_type` argument if needed.
```

### 根因

vLLM v0.23.0 的 `get_model_path` 函数：
- 如果 `os.path.exists(model)` 为 True，直接返回路径
- 否则走 HF API 的 `snapshot_download`，该函数会验证 repo_id 格式

模型在 GPU 节点 `/home/data/model/glm-4-9b-chat`（数据盘），但 `deploy-model.sh` 的 volume
mount 是 `MODEL_CACHE=/root/models → /root/models`（根盘），容器里找不到 `/home/data/model`，
`os.path.exists` 返回 False，导致走 HF API 验证并报错。

尝试用 symlink（`/root/models/hub/glm-4-9b-chat → /home/data/model/glm-4-9b-chat`）无效，
因为 vLLM 内部会调用 `os.path.realpath()` 解析 symlink 得到真实路径，然后重新验证失败。

### 解决方案

将 deployment 的 volume hostPath 和 mountPath 都直接设置为 `/home/data/model/glm-4-9b-chat`，
同时 args 里的模型路径也保持一致：

```yaml
volumes:
- name: model-cache
  hostPath:
    path: /home/data/model/glm-4-9b-chat   # 直接挂载模型目录
    type: DirectoryOrCreate

containers:
- volumeMounts:
  - name: model-cache
    mountPath: /home/data/model/glm-4-9b-chat   # mountPath 与 hostPath 一致

args:
- /home/data/model/glm-4-9b-chat   # 模型路径
```

这样 `os.path.exists('/home/data/model/glm-4-9b-chat')` 返回 True，直接使用本地路径。

### 在 start-glm4-9b.sh 里的修复

```bash
# 需要独立的部署 yaml 或传入额外参数
# deploy-model.sh 不支持自定义 hostPath，需要直接用 kubectl apply
```

---

## 问题 2：trust_remote_code 缺失

### 现象

```
ValueError: The repository /home/data/model/glm-4-9b-chat contains custom code 
which must be executed to correctly load the model.
Please pass the argument `trust_remote_code=True` to allow custom code to be run.
```

### 根因

GLM-4 系列模型包含自定义模型代码（`configuration_chatglm.py` 等），需要 `--trust-remote-code`。
`deploy-model.sh` 默认不加此参数。

### 解决方案

在 deployment args 里追加 `--trust-remote-code`：

```bash
kubectl patch deployment glm-4-9b -n llm-d-precise-prefix-gw --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--trust-remote-code"}]'
```

或在 `start-glm4-9b.sh` 里使用独立部署脚本时加入此参数。

---

## 最终 start-glm4-9b.sh 修复

`start-glm4-9b.sh` 不能直接调用 `deploy-model.sh`（它不支持自定义 hostPath），
需要使用 `deploy-glm4-9b.sh`（类似 `deploy-glm-sglang.sh` 的方式，直接 kubectl apply）。

---

## 下载路径说明

GLM-4-9B 存放路径（GPU 节点 h200-12-3）：
- 实际路径：`/home/data/model/glm-4-9b-chat`（数据盘 `/home/data`，7TB）
- master 下载临时路径：`/root/models/hub/glm-4-9b-chat`（后续可清理）


---

## 问题 3：InferencePool selector label 冲突

两个池都用了相同的 guide label，EPP 选中所有 pod，路由混乱。

修复：各池使用独立 guide label：
- qwen: llm-d.ai/guide=precise-prefix-cache-routing
- glm:  llm-d.ai/guide=glm4-9b-pool

注意：Deployment selector 是 immutable，必须删除重建。

---

## 问题 4：单入口多模型路由

agentgateway 原生支持按请求体 model 字段路由（无需客户端改动）：

1. AgentgatewayPolicy (PreRouting): CEL 读取 request.body.model 写入 header
2. HTTPRoute: 按 header 路由到对应 InferencePool

配置文件：
- llm-d/deploy-precise-prefix-gateway/policy-model-routing.yaml
- llm-d/deploy-precise-prefix-gateway/httproute-model-routing.yaml

结果：http://116.198.67.18:31273 单入口，model=qwen/glm 自动路由。
