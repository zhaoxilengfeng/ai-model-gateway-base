#!/bin/bash
# expose-agentgateway-ui.sh — 访问 agentgateway Admin UI
#
# Admin UI 内置于 agentgateway proxy pod，监听 localhost:15000（仅绑定 127.0.0.1，不绑定 0.0.0.0）。
# 因此无法通过 NodePort 直接访问，必须通过 kubectl port-forward 建立隧道。
#
# UI 功能（Kubernetes 模式，只读）：
#   - Listeners：查看 proxy 绑定的端口和附加的路由
#   - Routes：查看所有路由规则及后端配置
#   - Policies：查看生效的策略
#   - Playground：CEL 表达式测试（唯一可交互功能）
#
# 用法:
#   bash expose-agentgateway-ui.sh               # 在本机启动 port-forward（默认）
#   bash expose-agentgateway-ui.sh remote 2015   # 在 master01 启动，转发到本地 2015 端口
#   bash expose-agentgateway-ui.sh status        # 查看 proxy pod 及 UI 端口状态
#   bash expose-agentgateway-ui.sh logs          # 实时查看 proxy 请求日志
#
# 访问地址（port-forward 启动后）: http://localhost:15000/ui/

set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GATEWAY_NAME="${GATEWAY_NAME:-llm-d-inference-gateway}"
UI_PORT="${UI_PORT:-15000}"
MODE="${1:-portforward}"
REMOTE_PORT="${2:-15000}"

# 找到运行中的 proxy pod
get_proxy_deployment() {
  # proxy deployment 由 agentgateway controller 自动创建，名称与 Gateway 资源相同
  echo "${GATEWAY_NAME}"
}

get_proxy_pod() {
  kubectl get pod -n "${NAMESPACE}" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $1}'
}

case "${MODE}" in
  status|info)
    echo "=== agentgateway Admin UI 状态 ==="
    echo ""
    DEPLOY=$(get_proxy_deployment)
    POD=$(get_proxy_pod)
    echo "  Deployment: ${DEPLOY}（namespace: ${NAMESPACE}）"
    echo "  Pod:        ${POD:-（未运行）}"

    if [[ -n "$POD" ]]; then
      POD_IP=$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath="{.status.podIP}" 2>/dev/null)
      IMAGE=$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath="{.spec.containers[0].image}" 2>/dev/null)
      echo "  Pod IP:     ${POD_IP}"
      echo "  镜像:       ${IMAGE}"
      echo ""
      echo "  Admin UI 绑定地址: localhost:${UI_PORT}（仅 pod 内部，不对外暴露）"
      echo "  访问方式:   kubectl port-forward（见下方命令）"
    fi
    echo ""
    echo "  port-forward 命令:"
    echo "    kubectl port-forward -n ${NAMESPACE} deployment/${DEPLOY} ${UI_PORT}:${UI_PORT}"
    echo "  访问地址:"
    echo "    http://localhost:${UI_PORT}/ui/"
    ;;

  portforward|pf|"")
    DEPLOY=$(get_proxy_deployment)
    POD=$(get_proxy_pod)

    if [[ -z "$POD" ]]; then
      echo "错误: 未找到运行中的 agentgateway proxy pod（namespace: ${NAMESPACE}）"
      echo "  检查: kubectl get pods -n ${NAMESPACE} -l gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}"
      exit 1
    fi

    echo "=== agentgateway Admin UI ==="
    echo "  Pod:      ${POD}"
    echo "  访问地址: http://localhost:${UI_PORT}/ui/"
    echo "  说明:     Kubernetes 模式下 UI 为只读，仅 CEL Playground 可交互"
    echo "  按 Ctrl+C 停止"
    echo ""
    kubectl port-forward -n "${NAMESPACE}" "deployment/${DEPLOY}" ${UI_PORT}:${UI_PORT}
    ;;

  remote)
    # 在 master01 节点后台启动 port-forward，并通过 SSH -L 将其转发到本地
    # 用法: bash expose-agentgateway-ui.sh remote [local-port]
    # 在本地执行: ssh -p 12026 -L <local-port>:127.0.0.1:<local-port> root@116.198.67.18
    DEPLOY=$(get_proxy_deployment)
    POD=$(get_proxy_pod)

    if [[ -z "$POD" ]]; then
      echo "错误: 未找到运行中的 proxy pod"
      exit 1
    fi

    echo "=== 在 master01 启动 port-forward ==="
    echo "  Pod:        ${POD}"
    echo "  监听端口:   127.0.0.1:${REMOTE_PORT}"
    echo ""
    echo "  然后在本地执行 SSH 隧道（MacOS/Linux）："
    echo "    ssh -p 12026 -L ${REMOTE_PORT}:127.0.0.1:${REMOTE_PORT} root@116.198.67.18 -N"
    echo "  访问地址:   http://localhost:${REMOTE_PORT}/ui/"
    echo ""

    # 在后台启动
    nohup kubectl port-forward -n "${NAMESPACE}" "deployment/${DEPLOY}" \
      ${REMOTE_PORT}:${UI_PORT} --address 127.0.0.1 \
      > /tmp/agentgateway-ui-portforward.log 2>&1 &
    PF_PID=$!
    echo "  port-forward PID: ${PF_PID}"
    echo "  日志: /tmp/agentgateway-ui-portforward.log"
    echo "  停止: kill ${PF_PID}"

    sleep 2
    if kill -0 $PF_PID 2>/dev/null; then
      echo "  ✓ port-forward 已启动"
    else
      echo "  ✗ port-forward 启动失败，查看日志:"
      cat /tmp/agentgateway-ui-portforward.log
      exit 1
    fi
    ;;

  logs)
    POD=$(get_proxy_pod)
    if [[ -z "$POD" ]]; then
      echo "错误: 未找到运行中的 agentgateway proxy pod"
      exit 1
    fi
    echo "=== agentgateway proxy 请求日志（实时）==="
    echo "  Pod: ${POD}"
    echo "  字段: gateway | route | endpoint | method | path | status | duration | selected_endpoint"
    echo ""
    kubectl logs -n "${NAMESPACE}" "${POD}" -f
    ;;

  *)
    cat << USAGE
用法: bash expose-agentgateway-ui.sh [command] [port]

命令:
  portforward   在本机通过 port-forward 访问 UI（默认）
                → 访问 http://localhost:${UI_PORT}/ui/
  remote [port] 在 master01 后台启动 port-forward，配合 SSH -L 隧道从外部访问
                → 本地执行: ssh -p 12026 -L ${UI_PORT}:127.0.0.1:${UI_PORT} root@116.198.67.18 -N
  status        查看 proxy pod 状态和 UI 访问说明
  logs          实时查看 proxy 请求日志

说明:
  Admin UI 绑定在 proxy pod 的 localhost:${UI_PORT}，不暴露到 pod 外部。
  NodePort 无法访问 UI，必须使用 port-forward 建立隧道。
USAGE
    exit 1
    ;;
esac
