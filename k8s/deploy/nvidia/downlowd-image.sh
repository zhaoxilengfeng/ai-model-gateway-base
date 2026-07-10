REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"
USER="731553103@qq.com"
PASS=$(cat ~/.docker/config.json | python3 -c "
import json,sys,base64
d=json.load(sys.stdin)
auth=d['auths']['registry.cn-hangzhou.aliyuncs.com']['auth']
print(base64.b64decode(auth).decode().split(':',1)[1])
")

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

declare -A images=(
  ["nvidia-device-plugin:v0.19.3"]="nvcr.io/nvidia/k8s-device-plugin:v0.19.3"
)

for cached in "${!images[@]}"; do
  original="${images[$cached]}"
  tarfile="$TMP/${cached//:/-}.tar"
  echo "--- $cached -> $original"
  skopeo copy \
    --override-os linux --override-arch amd64 \
    --src-creds "$USER:$PASS" \
    "docker://$REGISTRY/$cached" \
    "docker-archive:$tarfile:$original"
  ctr -n k8s.io image import "$tarfile"
  echo "  imported: $original"
done

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep "nvidia" | awk '{print $1}'
