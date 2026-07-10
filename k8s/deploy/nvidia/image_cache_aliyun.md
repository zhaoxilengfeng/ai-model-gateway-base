# nvidia-device-plugin v0.19.3 镜像阿里云缓存

NVIDIA Device Plugin 部署所需镜像已缓存至阿里云容器镜像服务。

## 仓库信息

- **Registry**: `registry.cn-hangzhou.aliyuncs.com`
- **命名空间**: `airouter`
- **登录账号**: `731553103@qq.com`

## 镜像映射

| 阿里云缓存地址 | 原始镜像名（部署用） |
|---|---|
| `registry.cn-hangzhou.aliyuncs.com/airouter/nvidia-device-plugin:v0.19.3` | `nvcr.io/nvidia/k8s-device-plugin:v0.19.3` |

## 前置要求

GPU 节点需满足：
1. 已安装 NVIDIA Driver（570.x+）
2. 已安装 NVIDIA Container Toolkit
3. containerd 配置使用 `nvidia-container-runtime` 作为默认 runtime：

```bash
# /etc/containerd/config.toml 中 runc.options 段需设置：
# BinaryName = '/usr/bin/nvidia-container-runtime'
# 修改后重启：systemctl restart containerd
```

## 部署命令

```bash
# 1. 拉取镜像到所有 GPU 节点
bash downlowd-image.sh

# 2. 安装
bash install.sh

# 3. 验证（GPU 节点应显示 nvidia.com/gpu 资源）
kubectl get nodes -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['items']:
    gpu=n['status'].get('allocatable',{}).get('nvidia.com/gpu','0')
    if int(gpu) > 0:
        print(n['metadata']['name'], gpu, 'GPU(s)')
"
```
