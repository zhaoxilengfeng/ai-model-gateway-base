# render service 启动失败：联网下载 tokenizer

## 问题现象

`precise-prefix-cache-routing-render` pod 状态 `ErrImagePull` 或启动后反复重启，日志中出现：

```
# 情况1：镜像拉取失败（docker.io 无法访问）
Failed to pull image "docker.io/vllm/vllm-openai-cpu:v0.23.0": dial tcp: i/o timeout

# 情况2：镜像拉取成功但启动失败（tokenizer 下载失败）
huggingface_hub.errors.LocalEntryNotFoundError: Cannot find an appropriate cached snapshot folder
```

## 根本原因

### 情况1：镜像拉取失败

官方 kustomize 的 render deployment 使用 `docker.io/vllm/vllm-openai-cpu:v0.23.0`，离线环境无法访问 docker.io，kubelet 直接拉取镜像失败。

### 情况2：tokenizer 下载失败

render service 启动时模型参数（args[0]）传的是 HuggingFace 模型 ID（如 `Qwen/Qwen3-32B`），vLLM 会尝试从 HuggingFace Hub 下载 tokenizer 文件，离线环境网络不通导致失败。

## 解决方案

### 情况1：预先导入镜像

```bash
# 在有公网的机器拉取 CPU 镜像
docker pull vllm/vllm-openai-cpu:v0.23.0
docker save vllm/vllm-openai-cpu:v0.23.0 -o vllm-openai-cpu-v0.23.0.tar

# 传到控制节点
scp vllm-openai-cpu-v0.23.0.tar root@<控制节点>:/tmp/

# 推送到阿里云仓库（供各节点拉取）
skopeo copy \
  docker-archive:/tmp/vllm-openai-cpu-v0.23.0.tar \
  docker://registry.cn-hangzhou.aliyuncs.com/airouter/vllm-openai-cpu:v0.23.0

# 或直接分发到各 worker 节点
for node_ip in 10.0.0.4 10.0.0.5; do
  cat /tmp/vllm-openai-cpu-v0.23.0.tar | ssh root@${node_ip} "ctr -n k8s.io image import -"
done
```

### 情况2：使用本地 snapshot 路径

render 的模型参数必须传**本地文件系统的 snapshot 绝对路径**，并设置 `HF_HUB_OFFLINE=1`，同时挂载 hostPath：

```yaml
command: ["vllm", "launch", "render"]
args:
- "/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/<hash>"
- "--port=8000"
- "--served-model-name=qwen25-7b-instruct"
env:
- name: HF_HUB_OFFLINE
  value: "1"
volumeMounts:
- name: model-cache
  mountPath: /root/models
volumes:
- name: model-cache
  hostPath:
    path: /root/models
```

查找本地 snapshot 路径：

```bash
ls /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/
```

**注意**：`install.sh` 已自动解析本地 snapshot 路径，通过 `RENDER_MODEL_PATH` 变量注入，无需手动指定。

## token-producer modelName 一致性

render `--served-model-name` 必须与 EPP `token-producer.modelName` 完全一致，否则 EPP 请求 tokenize 时会收到 404：

```
tokenization failed: vLLM render returned status 404: The model `Qwen/Qwen3-32B` does not exist.
```

检查当前 render 暴露的模型名：

```bash
RENDER_IP=$(kubectl get svc precise-prefix-cache-routing-render \
  -n llm-d-precise-prefix -o jsonpath='{.spec.clusterIP}')
curl http://${RENDER_IP}:8000/v1/models | python3 -m json.tool
```

## 时间线

| 时间 | 事件 |
|---|---|
| 2026-07-13 | render pod ErrImagePull，确认 docker.io 不可达 |
| 2026-07-13 | 手动导入 CPU 镜像到各节点，render 启动 |
| 2026-07-13 | render 启动后联网下载 tokenizer 失败（Qwen/Qwen3-32B 模型 ID） |
| 2026-07-13 | install.sh 改用本地 snapshot 路径 + HF_HUB_OFFLINE=1，问题解决 |
| 2026-07-13 | 发现 render modelName 与 EPP token-producer.modelName 不一致，加 --served-model-name 修复 |
