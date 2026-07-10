#!/bin/bash
# uninstall.sh — 卸载 NVIDIA Device Plugin
set -e

echo "=== Uninstall nvidia-device-plugin ==="
helm uninstall nvidia-device-plugin -n kube-system 2>/dev/null || echo "no helm release: nvidia-device-plugin"

echo ""
echo "=== Verify ==="
kubectl get nodes -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['items']:
    name=n['metadata']['name']
    gpu=n['status'].get('allocatable',{}).get('nvidia.com/gpu','0')
    print(f'  {name}: gpu={gpu}')
"

echo "Done."
