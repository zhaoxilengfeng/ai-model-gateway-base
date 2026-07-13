# agentgateway pod CrashLoopBackOff：CRD not found

## 问题现象

agentgateway controller pod 持续重启，日志中出现：

```
get agentgatewaybackends.agentgateway.dev: not found
```

或 kubectl apply CRD 时报：

```
metadata.annotations: Too long: may not be more than 262144 bytes
```

## 根本原因

agentgateway v1.3.1 的 Helm chart 中 **没有打包 CRD**（与 v1.1.0 不同），CRD 需要从 GitHub 单独下载并安装。

`kubectl apply -f` 安装大型 CRD 时会把整个 YAML 存入 `last-applied-configuration` annotation，超过 256KB 限制报错。

## 解决方案

### 步骤1：下载 agentgateway CRDs

```bash
AGW_VERSION="v1.3.1"
AGW_CRD_DIR="/root/deploy/llm-d-gateway/agentgateway-crds"
mkdir -p "$AGW_CRD_DIR"

AGW_CRD_BASE="https://raw.githubusercontent.com/agentgateway/agentgateway/${AGW_VERSION}/controller/install/helm/agentgateway-crds/templates"
for crd in agentgateway.dev_agentgatewaybackends.yaml \
           agentgateway.dev_agentgatewayparameters.yaml \
           agentgateway.dev_agentgatewaypolicies.yaml; do
  https_proxy=socks5h://127.0.0.1:1080 curl -sf "$AGW_CRD_BASE/$crd" -o "$AGW_CRD_DIR/$crd"
done
```

### 步骤2：用 --server-side 安装（绕过 annotation 大小限制）

```bash
kubectl apply --server-side -f "$AGW_CRD_DIR/"
```

`--server-side` 使用服务端 apply，不写入 `last-applied-configuration` annotation，避免大小限制问题。

### 步骤3：安装时跳过 chart 内置 CRD

```bash
helm upgrade --install agentgateway ./agentgateway \
  --skip-crds \          # 跳过 chart 自带 CRD（实际上没有）
  --set inferenceExtension.enabled=true \
  ...
```

## 自动化

`install.sh` 的 Step 2 已自动处理：

```bash
echo "=== 2. Install Agentgateway CRDs ==="
if [ -d "$AGW_CRD_DIR" ] && ls "$AGW_CRD_DIR"/*.yaml &>/dev/null; then
  kubectl apply --server-side -f "$AGW_CRD_DIR/"
else
  echo "  WARNING: $AGW_CRD_DIR 不存在，跳过"
fi
```

`prepare.sh` 的 Step 4 已自动下载 CRDs。

## 时间线

| 时间 | 事件 |
|---|---|
| 2026-07-10 | 升级 agentgateway v1.1.0 → v1.3.1，pod CrashLoop |
| 2026-07-10 | 确认 v1.3.1 不含 CRD，需单独安装 |
| 2026-07-10 | kubectl apply 报 annotation too long，改用 --server-side 解决 |
| 2026-07-10 | prepare.sh + install.sh 加入自动处理逻辑 |
