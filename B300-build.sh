#!/bin/bash
# B300 Gonka mlnode 部署 - build 镜像脚本
# 基于 LABOLTUS B200 镜像派生,删除 runner.py forced 字典 4 个键,让 admin API curl 能传参数
# 已验证: 2196 nonces/min (Kimi-K2.6 INT4 +138% 路径生效)

set -e

IMG_BASE="ghcr.io/laboltus/gonka-mlnode:kaitaku-b200-nginx"
IMG_NEW="laboltus-b300-curl"
RUNNER="/app/packages/api/src/api/inference/vllm/runner.py"

echo "=== Step 1: 清环境 ==="
docker rm -f tmp-edit 2>/dev/null || true

echo "=== Step 2: pull 基础镜像(如已有跳过) ==="
docker pull "$IMG_BASE"

echo "=== Step 3: 起临时容器 ==="
docker run -d --name tmp-edit --entrypoint sleep "$IMG_BASE" infinity

echo ""
echo "=== Step 4: [BEFORE] 原版 _b300_forced 字典 ==="
docker exec tmp-edit grep -A 10 "_b300_forced = {" "$RUNNER"

echo ""
echo "=== Step 5: sed 删 4 个强制键 ==="
docker exec tmp-edit sed -i \
    -e "/'--gpu-memory-utilization': '0.95',/d" \
    -e "/'--max-model-len': '120000',/d" \
    -e "/'--max-num-batched-tokens': '32768',/d" \
    -e "/'--max-num-seqs': '32',/d" \
    "$RUNNER"

echo ""
echo "=== Step 6: [AFTER] 改完的 _b300_forced 字典 ==="
AFTER=$(docker exec tmp-edit grep -A 10 "_b300_forced = {" "$RUNNER")
echo "$AFTER"

echo ""
echo "=== Step 7: 验证 4 个键已删 ==="
for key in "gpu-memory-utilization" "max-model-len': '120000" "max-num-batched-tokens" "max-num-seqs': '32"; do
    if echo "$AFTER" | grep -q "$key"; then
        echo "❌ FAIL: '$key' 还在,sed 没生效"
        docker rm -f tmp-edit
        exit 1
    fi
done
echo "✅ 4 个键全删掉了"

echo ""
echo "=== Step 8: 清 .pyc ==="
docker exec tmp-edit bash -c \
    'find /app/packages -name "*.pyc" -delete; find /app/packages -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null'

echo ""
echo "=== Step 9: commit 成新 image ==="
docker commit \
    --change 'CMD ["uvicorn", "api.app:app", "--host=0.0.0.0", "--port=8080"]' \
    --change 'ENTRYPOINT ["/entrypoint.sh"]' \
    tmp-edit "$IMG_NEW"

docker rm -f tmp-edit

echo ""
echo "=== Step 10: 从新 image 验证真实内容 ==="
docker run --rm --entrypoint cat "$IMG_NEW" "$RUNNER" | grep -A 10 "_b300_forced = {"

echo ""
echo "=== Image 信息(应该是 ~44GB) ==="
docker images | grep -E "${IMG_NEW}|REPOSITORY" | head -3

echo ""
echo "✅ DONE - 镜像 $IMG_NEW 就绪"
