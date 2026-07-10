# llm-d Standalone 模式部署

基于官方 [optimized-baseline](https://github.com/llm-d/llm-d/tree/v0.8.1/guides/optimized-baseline) 指南，使用 `llm-d-router-standalone` chart。

## 架构

```
Client → EPP Service (ClusterIP) → Envoy sidecar → vLLM pods
```

Router Standalone 模式内置 Envoy proxy（作为 EPP pod 的 sidecar），不依赖外部 Gateway controller。

## 组件版本

| 组件 | 版本 |
|---|---|
| llm-d-router-standalone chart | v0.9.0 |
| llm-d-router-endpoint-picker (EPP) | v0.9.0 |
| envoyproxy/envoy | distroless-v1.33.2 |
| vllm/vllm-openai | v0.23.0（需要 NVIDIA 驱动 ≥ 580，CUDA 13.0） |
| GIE CRDs | v1.5.0 |

## 部署流程

```bash
# 1. 下载依赖（chart + GIE manifests）
bash prepare.sh

# 2. 拉取镜像到本地 containerd
bash downlowd-image.sh

# 3. 安装
bash install.sh

# 4. 部署模型
bash deploy-model.sh

# 5. 验证服务
bash test-llmd.sh
```

## 注意事项

### GPU 驱动要求

vLLM v0.23.0 镜像内置 CUDA 13.0，**宿主机 NVIDIA 驱动必须 ≥ 580**。

驱动版本不匹配会导致 pod `CrashLoopBackOff`，错误信息为：
```
RuntimeError: Error 804: forward compatibility was attempted on non supported HW
```

集群各节点驱动版本确认方式：
```bash
# 在各 worker 节点执行
nvidia-smi | head -3
```

升级方式（Ubuntu 22.04）：
```bash
apt-get install -y nvidia-driver-580
reboot
```

升级前先 cordon 节点，重启后 uncordon：
```bash
kubectl cordon <node>
# ... reboot ...
kubectl uncordon <node>
```

### 镜像分发

各 worker 节点需要预先拉取镜像，否则调度到无镜像节点会 `ErrImagePull`（集群无法访问外网时）。

在每个节点上执行 `downlowd-image.sh`，或通过管道从已有镜像的节点导入：
```bash
# 从 node-A 导入到 node-B（在控制节点执行）
ssh root@<node-A> "ctr -n k8s.io images export - docker.io/vllm/vllm-openai:v0.23.0" \
  | ssh root@<node-B> "ctr -n k8s.io images import -"
```

## 访问方式

```bash
# EPP Service ClusterIP（集群内）
export IP=$(kubectl get svc quickstart-epp -n llm-d-standalone -o jsonpath='{.spec.clusterIP}')
curl http://${IP}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

## 卸载

```bash
# 全量清理（含 llm-d-standalone 和 llm-d 两个 namespace）
bash uninstall.sh

# 仅清理某个模型
MODEL_NAME=qwen25-7b-instruct bash uninstall.sh
```

`uninstall.sh` 会依次清理：
1. `llm-d-standalone` namespace（EPP + 模型 deployment）
2. `llm-d` namespace（modelservice + redis）
3. GIE CRDs
