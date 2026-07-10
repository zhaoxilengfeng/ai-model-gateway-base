# llm-d v0.8.1 镜像阿里云缓存

llm-d v0.8.1 部署所需镜像已缓存至阿里云容器镜像服务，用于无法直连 ghcr.io / DockerHub 的环境。

## 仓库信息

- **Registry**: `registry.cn-hangzhou.aliyuncs.com`
- **命名空间**: `airouter`
- **登录账号**: `731553103@qq.com`
- **登录命令**:
  ```bash
  docker login --username=731553103@qq.com registry.cn-hangzhou.aliyuncs.com
  ```

## 镜像映射

| 阿里云缓存地址 | 原始镜像名（部署用） |
|---|---|
| `registry.cn-hangzhou.aliyuncs.com/airouter/llm-d-router-endpoint-picker:v0.9.0` | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` |
| `registry.cn-hangzhou.aliyuncs.com/airouter/llm-d-router-disagg-sidecar:v0.9.0` | `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0` |
| `registry.cn-hangzhou.aliyuncs.com/airouter/vllm-openai:v0.23.0` | `vllm/vllm-openai:v0.23.0` |

## 版本说明

llm-d v0.8.1 相比 v0.8.0 的镜像变化：

| 组件 | v0.8.0 | v0.8.1 |
|---|---|---|
| EPP | `llm-d-inference-scheduler:v0.8.0` | `llm-d-router-endpoint-picker:v0.9.0`（改名）|
| routing sidecar | `llm-d-routing-sidecar:v0.8.0` | `llm-d-router-disagg-sidecar:v0.9.0`（改名）|
| vLLM | `vllm-openai:v0.8.5` | `vllm-openai:v0.23.0` |

## 拉取并还原脚本

在目标节点执行以下脚本，拉取后自动 retag 为原始镜像名，部署无需修改任何配置：

```bash
docker login --username=731553103@qq.com registry.cn-hangzhou.aliyuncs.com

REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"

declare -A images=(
  ["llm-d-router-endpoint-picker:v0.9.0"]="ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0"
  ["llm-d-router-disagg-sidecar:v0.9.0"]="ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0"
  ["vllm-openai:v0.23.0"]="vllm/vllm-openai:v0.23.0"
)

for cached in "${!images[@]}"; do
  original="${images[$cached]}"
  docker pull "$REGISTRY/$cached"
  docker tag  "$REGISTRY/$cached" "$original"
done
```

## 部署命令

镜像就位后，按以下顺序部署：

```bash
# 1. 安装基础组件（Gateway API CRDs + GIE CRDs + EPP RBAC）
bash install.sh

# 2. 部署模型
bash deploy-model.sh <model-name> <model-path> [replicas] [node]
```
