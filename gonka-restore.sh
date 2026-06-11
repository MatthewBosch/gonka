#!/bin/bash
# gonka-restore.sh
# 从 /root/gonka-backup 恢复 gonka keys (cold + warm + node identity + tmkms)
# 不碰容器. 恢复完自己确认密码后手动起/重启容器.
# 用法: bash gonka-restore.sh
set -e
B=/root/gonka-backup

echo "=== [0/5] 检查备份存在 ==="
for f in "$B/cold-key/keyring-file" "$B/warm-key/keyring-file" "$B/node-identity/node_key.json"; do
  [ -e "$f" ] || { echo "缺失! $f — 备份不完整, 停止"; exit 1; }
  echo "  OK $f"
done

echo "=== [1/5] 恢复 Cold key ==="
mkdir -p /root/.inference/keyring-file/
cp -av "$B/cold-key/keyring-file/." /root/.inference/keyring-file/
chmod 700 /root/.inference/keyring-file/
chmod 600 /root/.inference/keyring-file/*

echo "=== [2/5] 恢复 Warm key ==="
mkdir -p /root/gonka/deploy/join/.inference/keyring-file/
cp -av "$B/warm-key/keyring-file/." /root/gonka/deploy/join/.inference/keyring-file/
chmod 700 /root/gonka/deploy/join/.inference/keyring-file/
chmod 600 /root/gonka/deploy/join/.inference/keyring-file/*

echo "=== [3/5] 恢复 Node identity ==="
mkdir -p /root/gonka/deploy/join/.inference/config/
cp -av "$B/node-identity/node_key.json" /root/gonka/deploy/join/.inference/config/node_key.json
chmod 600 /root/gonka/deploy/join/.inference/config/node_key.json

echo "=== [4/5] 恢复 TMKMS ==="
if [ -d "$B/tmkms/secrets" ]; then
  mkdir -p /root/gonka/deploy/join/.tmkms/secrets/
  cp -av "$B/tmkms/secrets/." /root/gonka/deploy/join/.tmkms/secrets/
  chmod 700 /root/gonka/deploy/join/.tmkms/secrets/
  chmod 600 /root/gonka/deploy/join/.tmkms/secrets/*
else
  echo "  备份里没有 tmkms, 跳过"
fi

echo "=== [5/5] 恢复结果检查 ==="
echo "  cold:  $(ls /root/.inference/keyring-file/*.info 2>/dev/null)"
echo "  warm:  $(ls /root/gonka/deploy/join/.inference/keyring-file/*.info 2>/dev/null)"
echo "  node:  $(ls -la /root/gonka/deploy/join/.inference/config/node_key.json 2>/dev/null | awk '{print $NF}')"
echo "  tmkms: $(ls /root/gonka/deploy/join/.tmkms/secrets/ 2>/dev/null | tr '\n' ' ')"

echo ""
echo "============ 恢复完成 (容器没动) ============"
echo "下一步 (手动):"
echo "  1) 确认 KEYRING_PASSWORD 跟原来一致"
echo "  2) 自己起/重启容器"
