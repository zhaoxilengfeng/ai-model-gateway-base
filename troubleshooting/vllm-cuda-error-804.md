# vLLM pod CrashLoopBackOff：CUDA Error 804

## 问题现象

vLLM pod 启动后反复重启，`kubectl describe pod` 或日志中出现：

```
RuntimeError: Error 804: forward compatibility was attempted on non supported HW
```

## 根本原因

vLLM v0.23.0 镜像内置 CUDA 13.0，要求宿主机 NVIDIA 驱动版本 **≥ 580**。

宿主机驱动版本 575 不满足 CUDA 13.0 的 forward compatibility 要求，报 Error 804。

## 排查步骤

```bash
# 查看各节点驱动版本
for node in host-000-002 host-000-004 host-000-005; do
  echo -n "$node: "
  ssh root@${node} "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1"
done

# 查看 pod 调度到哪个节点
kubectl get pod <pod-name> -o wide

# 查看 pod 错误日志
kubectl logs <pod-name> | grep -i "error\|cuda\|driver"
```

## 解决方案

### 方案一：升级宿主机驱动到 580+

```bash
# Ubuntu 22.04
apt-get install -y nvidia-driver-580
reboot
```

**注意**：若 apt 报依赖冲突（如 `libnvidia-extra-575` 阻止安装），需先强制移除旧版本残留：

```bash
dpkg --force-all --remove libnvidia-extra-575 libnvidia-gl-575
apt-get install -y nvidia-driver-580
```

### 方案二：nodeAffinity 限制调度到驱动 ≥ 580 的节点

在 Deployment spec 中加 nodeAffinity：

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia-driver-version
            operator: In
            values: ["580"]
```

需提前给节点打 label：

```bash
kubectl label node host-000-004 nvidia-driver-version=580
kubectl label node host-000-005 nvidia-driver-version=580
```

## 环境信息

| 节点 | 驱动版本 | 状态 |
|---|---|---|
| host-000-002 | 575 → 580（已升级）| 已修复 |
| host-000-004 | 580 | 正常 |
| host-000-005 | 580 | 正常 |

## 时间线

| 时间 | 事件 |
|---|---|
| 2026-07-10 | 首次部署 vLLM v0.23.0，host-000-002 报 Error 804 |
| 2026-07-10 | 确认根因为驱动版本不兼容，临时将 pod 调度到 004/005 |
| 2026-07-10 | 升级 host-000-002 驱动到 580，重启节点后正常 |
