# models — 各模型快捷启停脚本

每个模型一对脚本：`start-<model>.sh` 启动，`stop-<model>.sh` 销毁。

脚本内部调用上级目录的 `deploy-*.sh` / `undeploy-model.sh`，不重复定义部署逻辑。

## 已有模型

| 模型 | 框架 | GPU | NodePort | 启动 | 销毁 |
|------|------|-----|----------|------|------|
| GLM-5.2-FP8 | sglang | 8×H200（整机） | 30001 | `bash start-glm-5-2-fp8.sh` | `bash stop-glm-5-2-fp8.sh` |

> **注意**：GLM-5.2-FP8 占用整机全部 8 张 GPU，启动前需确保 h200-12-3 上无其他模型。

## 使用方式

```bash
cd /root/ai-model-gateway-base/llm-d/deploy-precise-prefix-gateway/models

# 启动 GLM
bash start-glm-5-2-fp8.sh

# 销毁 GLM
bash stop-glm-5-2-fp8.sh
```

## 新增模型

1. 在上级目录添加对应的 `deploy-<model>.sh`
2. 在本目录新建 `start-<model>.sh` 和 `stop-<model>.sh`，调用上级脚本
3. 更新本文件的模型列表
