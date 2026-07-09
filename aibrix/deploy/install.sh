#!/bin/bash
set -e

AIBRIX_CHART_DIR="${AIBRIX_CHART_DIR:-/root/deploy/aibrix/dist/chart}"
ENVOY_GATEWAY_CHART_DIR="${ENVOY_GATEWAY_CHART_DIR:-/root/deploy/envoy-gateway/charts/gateway-helm}"

echo "=== 1. Install Envoy Gateway (envoy-gateway-system) ==="
# values.tmpl.yaml contains placeholders, generate values.yaml before install
sed \
  -e 's|${GatewayImage}|docker.io/envoyproxy/gateway:v1.2.8|g' \
  -e 's|${GatewayImagePullPolicy}|IfNotPresent|g' \
  "$ENVOY_GATEWAY_CHART_DIR/values.tmpl.yaml" > "$ENVOY_GATEWAY_CHART_DIR/values.yaml"

helm install eg "$ENVOY_GATEWAY_CHART_DIR" \
  -n envoy-gateway-system --create-namespace

echo "=== 2. Enable EnvoyPatchPolicy (required for AIBrix) ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-gateway-config
  namespace: envoy-gateway-system
data:
  envoy-gateway.yaml: |
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyGateway
    provider:
      type: Kubernetes
    gateway:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    extensionApis:
      enableEnvoyPatchPolicy: true
EOF

echo "=== 3. Install AIBrix CRDs ==="
kubectl apply -f "$AIBRIX_CHART_DIR/crds/"

echo "=== 4. Install AIBrix ==="
helm install aibrix "$AIBRIX_CHART_DIR" \
  -f "$AIBRIX_CHART_DIR/stable.yaml" \
  -n aibrix-system --create-namespace

echo ""
echo "=== Verify ==="
kubectl get pods -n envoy-gateway-system
kubectl get pods -n aibrix-system

echo "Done."
