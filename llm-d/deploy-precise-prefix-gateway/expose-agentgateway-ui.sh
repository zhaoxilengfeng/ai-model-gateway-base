#!/bin/bash
# expose-agentgateway-ui.sh — 访问 agentgateway Admin UI
#
# Admin UI 内置于 agentgateway proxy pod 的 :15000 端口。
#
# ⚠️  版本说明：
#     当前集群使用 agentgateway v1.3.1，该版本 proxy pod 未开放 :15000 端口。
#     Admin UI（含 Listeners/Routes/Policies/CEL Playground）
#     在更高版本中可用，升级后可通过本脚本暴露。
#
#     当前可用的观察手段（v1.3.1）：
#       - proxy pod 日志（每条请求含路由结果）
#       - controller metrics（:9092/metrics）
#
# 用法:
#   bash expose-agentgateway-ui.sh              # port-forward 模式（默认）
#   bash expose-agentgateway-ui.sh nodeport     # 创建 NodePort Service
#   bash expose-agentgateway-ui.sh nodeport 32015  # 指定 NodePort 端口
#   bash expose-agentgateway-ui.sh remove       # 删除 NodePort Service
#   bash expose-agentgateway-ui.sh status       # 查看当前版本及端口状态
#   bash expose-agentgateway-ui.sh logs         # 实时查看 proxy 请求日志

set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GATEWAY_NAME="${GATEWAY_NAME:-llm-d-inference-gateway}"
UI_PORT=15000
NODEPORT="${2:-32015}"
MODE="${1:-portforward}"
SVC_NAME="agentgateway-ui"

# 找到 proxy pod
get_proxy_pod() {
  kubectl get pod -n "${NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $1}'
}

# 检查 UI 端口是否可用
check_ui_port() {
  local POD_IP
  POD_IP=$(kubectl get pod -n "${NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $6}')
  if [[ -z "$POD_IP" ]]; then return 1; fi
  curl -s --max-time 2 "http://${POD_IP}:${UI_PORT}/ui/" &>/dev/null
}

case "${MODE}" in
  status)
    echo "=== agentgateway 版本与 UI 端口状态 ==="
    IMAGE=$(kubectl get deployment -n "${NAMESPACE}" \
      -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
      -o jsonpath="{.items[0].spec.template.spec.containers[0].image}" 2>/dev/null)
    echo "  proxy 镜像:  ${IMAGE}"
    POD=$(get_proxy_pod)
    echo "  proxy pod:   ${POD:-未运行}"
    if [[ -n "$POD" ]]; then
      POD_IP=$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath="{.status.podIP}")
      echo "  pod IP:      ${POD_IP}"
      if check_ui_port; then
        echo "  UI 端口:     :${UI_PORT} ✅ 可用"
      else
        echo "  UI 端口:     :${UI_PORT} ❌ 未开放（当前版本不支持）"
        echo ""
        echo "  当前可用的观察方式："
        echo "    proxy 请求日志:  kubectl logs -n ${NAMESPACE} ${POD} -f"
        echo "    controller 指标: kubectl port-forward -n agentgateway-system deploy/agentgateway 9092"
        echo "                     curl http://localhost:9092/metrics"
      fi
    fi
    ;;

  portforward|pf)
    POD=$(get_proxy_pod)
    if [[ -z "$POD" ]]; then
      echo "错误: 未找到运行中的 agentgateway proxy pod"
      exit 1
    fi
    echo "=== agentgateway Admin UI (port-forward) ==="
    echo "  Pod:      ${POD}"
    echo "  访问地址: http://localhost:${UI_PORT}/ui/"
    echo ""
    if ! check_ui_port; then
      echo "  ⚠️  警告: :${UI_PORT} 端口未响应，当前版本可能不支持 Admin UI"
      echo "  尝试连接中，如果 UI 已在更新版本中可用则正常访问..."
      echo ""
    fi
    echo "  按 Ctrl+C 停止"
    kubectl port-forward -n "${NAMESPACE}" "pod/${POD}" ${UI_PORT}:${UI_PORT}
    ;;

  nodeport|np)
    echo "=== 创建 agentgateway UI NodePort Service ==="
    echo "  Namespace: ${NAMESPACE}"
    echo "  NodePort:  ${NODEPORT}"
    echo ""
    if ! check_ui_port; then
      echo "  ⚠️  警告: 当前 agentgateway v1.3.1 的 proxy pod 未开放 :${UI_PORT} 端口"
      echo "  Service 将被创建，但 UI 需升级到支持版本后才可访问"
      echo ""
    fi

    kubectl apply -n "${NAMESPACE}" -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: agentgateway-ui
  annotations:
    note: "agentgateway Admin UI - requires agentgateway version with UI support (port 15000)"
spec:
  type: NodePort
  selector:
    gateway.networking.k8s.io/gateway-name: ${GATEWAY_NAME}
  ports:
  - name: ui
    port: ${UI_PORT}
    targetPort: ${UI_PORT}
    nodePort: ${NODEPORT}
    protocol: TCP
YAML

    echo ""
    echo "=== NodePort Service 已创建 ==="
    kubectl get svc -n "${NAMESPACE}" "${SVC_NAME}"
    echo ""
    echo "就绪后访问: http://116.198.67.18:${NODEPORT}/ui/"
    echo ""
    echo "删除时执行: bash expose-agentgateway-ui.sh remove"
    ;;

  remove|delete|rm)
    echo "=== 删除 agentgateway UI NodePort Service ==="
    if kubectl delete svc "${SVC_NAME}" -n "${NAMESPACE}" 2>/dev/null; then
      echo "  ✓ Service ${SVC_NAME} 已删除"
    else
      echo "  跳过: Service ${SVC_NAME} 不存在"
    fi
    ;;

  logs)
    POD=$(get_proxy_pod)
    if [[ -z "$POD" ]]; then
      echo "错误: 未找到运行中的 agentgateway proxy pod"
      exit 1
    fi
    echo "=== agentgateway proxy 请求日志 (实时) ==="
    echo "  Pod: ${POD}"
    echo "  字段说明: gateway | listener | route | endpoint | method | path | status | duration"
    echo ""
    kubectl logs -n "${NAMESPACE}" "${POD}" -f
    ;;

  *)
    echo "用法: bash expose-agentgateway-ui.sh [command] [nodeport-port]"
    echo ""
    echo "  status          查看当前版本及 UI 端口可用状态"
    echo "  portforward     本地 port-forward，访问 http://localhost:15000/ui/"
    echo "  nodeport [port] 创建 NodePort Service 对外暴露（默认端口 32015）"
    echo "  remove          删除 NodePort Service"
    echo "  logs            实时查看 proxy 请求日志（当前版本的替代观察方式）"
    exit 1
    ;;
esac
