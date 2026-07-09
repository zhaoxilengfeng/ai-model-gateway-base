#!/bin/bash
set -e

echo "=== 1. Helm uninstall aibrix ==="
helm uninstall aibrix -n aibrix-system 2>/dev/null || echo "no helm release: aibrix"
helm uninstall kuberay-operator -n aibrix-system 2>/dev/null || echo "no helm release: kuberay-operator"

echo "=== 2. Delete aibrix-system namespace ==="
kubectl delete namespace aibrix-system --timeout=60s 2>/dev/null || echo "no namespace: aibrix-system"

echo "=== 3. Delete aibrix cluster-scoped resources ==="
kubectl get clusterrole,clusterrolebinding 2>/dev/null | grep aibrix | awk '{print $1}' | xargs -r kubectl delete
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration 2>/dev/null | grep aibrix | awk '{print $1}' | xargs -r kubectl delete

echo "=== 4. Delete aibrix CRDs ==="
kubectl get crd 2>/dev/null | grep aibrix | awk '{print $1}' | xargs -r kubectl delete crd

echo "=== 5. Helm uninstall eg (envoy-gateway) ==="
helm uninstall eg -n envoy-gateway-system 2>/dev/null || echo "no helm release: eg"

echo "=== 6. Delete envoy-gateway-system namespace ==="
kubectl delete namespace envoy-gateway-system --timeout=60s 2>/dev/null || echo "no namespace: envoy-gateway-system"

echo "=== 7. Delete envoy-gateway cluster-scoped resources ==="
kubectl get clusterrole,clusterrolebinding 2>/dev/null | grep -E "envoy|gateway" | awk '{print $1}' | xargs -r kubectl delete

echo "=== 8. Delete Gateway API & Envoy CRDs ==="
kubectl get crd 2>/dev/null | grep -E "envoyproxy|gateway" | awk '{print $1}' | xargs -r kubectl delete crd

echo "=== 9. Delete Ray CRDs (optional, comment out if want to keep) ==="
kubectl get crd 2>/dev/null | grep "ray.io" | awk '{print $1}' | xargs -r kubectl delete crd

echo ""
echo "=== Verify ==="
kubectl get ns | grep -E "aibrix|envoy|ray" || echo "all namespaces cleaned"
kubectl get crd | grep -E "aibrix|envoy|gateway|ray" || echo "all CRDs cleaned"

echo "Done."
