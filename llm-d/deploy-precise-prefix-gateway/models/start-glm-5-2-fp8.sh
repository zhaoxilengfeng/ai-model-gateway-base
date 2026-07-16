#!/bin/bash
# 启动 GLM-5.2-FP8（sglang，8×H200，NodePort 30001）
#
# 注意：模型占用整机 8 张 GPU，启动前确保 h200-12-3 上无其他模型运行
# 首次启动需 DeepGEMM JIT 预编译，约需 15-20 分钟；后续重启约 8-10 分钟

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

bash "${DEPLOY_DIR}/deploy-glm-sglang.sh"

echo ""
echo "=== 等待模型就绪（预计 8-20 分钟）==="
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
POD=""
for i in $(seq 1 12); do
  POD=$(kubectl get pod -n "${NAMESPACE}" -l app=glm-5-2-fp8 --no-headers 2>/dev/null | head -1 | awk '{print $1}')
  [[ -n "$POD" ]] && break
  sleep 5
done

if [[ -z "$POD" ]]; then
  echo "  pod 未调度，请检查: kubectl get pods -n ${NAMESPACE}"
  exit 1
fi

echo "  Pod: ${POD}，可用以下命令跟踪启动日志："
echo "  kubectl logs -n ${NAMESPACE} ${POD} -f | grep -E 'ready to roll|CUDA graph|DeepGEMM|ERROR'"
echo ""
echo "  就绪后测试命令："
echo "  curl http://116.198.67.18:31273/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"glm-5-2-fp8\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":100}'"
