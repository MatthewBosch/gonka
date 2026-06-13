#!/bin/bash
# gonka-full-restore.sh
# 整合钱包恢复: 停容器 -> 检查备份 -> 文件恢复 -> cold key 助记词恢复 -> 重建 config.env
#   -> 起 tmkms/node -> 提示容器内命令(你手动) -> register x2 -> submit 面板IP -> 验证 -> restart api
# 交互点: 回车确认 / cold 助记词+密码 / ACCOUNT_PUBKEY / 容器内手动 / 热钱包地址 / 冷钱包地址
set -e

J=/root/gonka/deploy/join
B=/root/gonka-backup

# ============ [1] 停容器 ============
echo "=== [1] docker stop node api ==="
docker stop node api 2>/dev/null || echo "  (容器不存在/已停, 继续)"

# ============ [1.5] payload 恢复 (有 /root/inference-backup 才做, 没有跳过) ============
echo ""
echo "=== [1.5] payload 恢复检查 ==="
if [ -d /root/inference-backup ]; then
  CNT=$(ls /root/inference-backup/ 2>/dev/null | wc -l)
  SZ=$(du -sh /root/inference-backup/ 2>/dev/null | cut -f1)
  echo "  发现 /root/inference-backup ($SZ, 顶层 $CNT 项)"
  read -p ">>> 回车开始复制 payload 到 .dapi/data/inference/ (Ctrl+C 取消): " _
  mkdir -p /root/gonka/deploy/join/.dapi/data/inference/
  # rsync 增量: 第一次全量, 重复跑只补缺的/变的, 不重抄 48G
  if command -v rsync >/dev/null 2>&1; then
    rsync -a /root/inference-backup/ /root/gonka/deploy/join/.dapi/data/inference/
  else
    cp -a /root/inference-backup/. /root/gonka/deploy/join/.dapi/data/inference/
  fi
  echo ""
  echo "  --- payload 恢复完成 ---"
  du -sh /root/gonka/deploy/join/.dapi/data/inference/
  for EP in $(ls /root/gonka/deploy/join/.dapi/data/inference/ | sort -n); do
    echo "  epoch $EP: $(ls /root/gonka/deploy/join/.dapi/data/inference/$EP/ 2>/dev/null | wc -l) 文件"
  done
else
  echo "  /root/inference-backup 不存在, 跳过 payload 恢复"
fi

# ============ [2] 检查备份 + 提取 KEY_NAME ============
echo ""
echo "=== [2] 检查备份 $B ==="
for f in "$B/cold-key/keyring-file" "$B/warm-key/keyring-file" "$B/node-identity/node_key.json"; do
  [ -e "$f" ] || { echo "缺失! $f — 备份不完整, 停止"; exit 1; }
  echo "  OK $f"
done
COLD_NAME=$(ls "$B/cold-key/keyring-file/"*.info 2>/dev/null | head -1 | xargs -n1 basename | sed 's/\.info$//')
WARM_NAME=$(ls "$B/warm-key/keyring-file/"*.info 2>/dev/null | head -1 | xargs -n1 basename | sed 's/\.info$//')
[ -n "$COLD_NAME" ] || { echo "cold key .info 没找到, 停止"; exit 1; }
[ -n "$WARM_NAME" ] || { echo "warm key .info 没找到, 停止"; exit 1; }
echo ""
echo "  COLD KEY_NAME = $COLD_NAME"
echo "  WARM KEY_NAME = $WARM_NAME"
echo ""
read -p ">>> 确认上面 KEY_NAME 正确, 回车继续 (Ctrl+C 取消): " _

# ============ [3] 文件恢复 (node_key.json + tmkms + keyring 文件) ============
echo ""
echo "=== [3] wget + 跑 gonka-restore.sh ==="
wget -q https://raw.githubusercontent.com/MatthewBosch/gonka/refs/heads/main/gonka-restore.sh -O /root/gonka-restore.sh
chmod +x /root/gonka-restore.sh
bash /root/gonka-restore.sh

# ============ [4] cold key 助记词恢复 ============
echo ""
echo "=== [4] cold key 助记词恢复: $COLD_NAME ==="
echo "  (接下来交互: 输助记词 + 密码; 如提示 override 已存在, 输 y 覆盖)"
cd "$J"
./inferenced keys add "$COLD_NAME" --keyring-backend file --recover

# ============ [5] 重建 config.env ============
echo ""
echo "=== [5] 重建 config.env ==="
rm -f "$J/.env" "$J/config.env"

# 本机公网 IP (IMDSv2 -> IMDSv1 -> 外部)
TOK=$(curl -s -m 3 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [ -n "$TOK" ]; then
  MYIP=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
fi
[ -n "$MYIP" ] || MYIP=$(curl -s -m 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
[ -n "$MYIP" ] || MYIP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || true)
[ -n "$MYIP" ] || { echo "本机公网 IP 获取失败, 停止"; exit 1; }
echo "  本机 IP: $MYIP"

# ACCOUNT_PUBKEY 输入 + 验证 (base64, 解码后 33 字节压缩公钥)
while true; do
  read -p ">>> 输入 ACCOUNT_PUBKEY (冷钱包公钥, 形如 AwgiYPLm...): " PK
  PK=$(echo "$PK" | tr -d ' ')
  BYTES=$(echo -n "$PK" | base64 -d 2>/dev/null | wc -c || echo 0)
  if [ "${#PK}" = "44" ] && [ "$BYTES" = "33" ]; then
    echo "  pubkey 格式 OK (44 字符 base64, 解码 33 字节)"
    break
  else
    echo "  格式不对 (长度=${#PK} 应44, 解码=${BYTES}字节 应33), 重输"
  fi
done

cat > "$J/config.env" << EOF
export KEY_NAME=$WARM_NAME
export KEYRING_PASSWORD=square831009
export NGINX_MODE=http
export API_PORT=8000
export PUBLIC_URL=http://$MYIP:8000
export P2P_EXTERNAL_ADDRESS=tcp://$MYIP:5000
export ACCOUNT_PUBKEY=$PK
export NODE_CONFIG=./node-config.json
export HF_HOME=/mnt/shared
export SEED_API_URL=http://node1.gonka.ai:8000
export SEED_NODE_RPC_URL=http://node1.gonka.ai:8000/chain-rpc/
export SEED_NODE_P2P_URL=tcp://node1.gonka.ai:5000
export DAPI_API__POC_CALLBACK_URL=http://$MYIP:9100
export DAPI_CHAIN_NODE__URL=http://node:26657
export DAPI_CHAIN_NODE__P2P_URL=http://node:26656
export RPC_SERVER_URL_1=http://node1.gonka.ai:8000/chain-rpc/
export RPC_SERVER_URL_2=http://node2.gonka.ai:8000/chain-rpc/
export PORT=8080
export INFERENCE_PORT=5050
export KEYRING_BACKEND=file
EOF
echo "  config.env 写好 (KEY_NAME=$WARM_NAME, IP=$MYIP)"
cp "$J/config.env" "$J/.env"
source "$J/config.env"

# ============ [6] 起 tmkms + node ============
echo ""
echo "=== [6] docker compose up tmkms node -d --no-deps ==="
cd "$J"
docker compose up tmkms node -d --no-deps

# ============ [7] 容器内手动操作 (命令已备好, 直接复制) ============
echo ""
echo "============================================================"
echo ">>> 即将进入 api 容器. 进去后按顺序复制粘贴这 3 条:"
echo "============================================================"
echo ""
echo "inferenced keys add $WARM_NAME --recover --keyring-backend file"
echo ""
echo 'inferenced register-new-participant $DAPI_API__PUBLIC_URL $ACCOUNT_PUBKEY --node-address "http://node1.gonka.ai:8000"'
echo ""
echo "exit"
echo ""
echo "============================================================"
echo "说明: 第1条恢复热钱包(输助记词); 第2条容器内注册; 第3条退出."
echo "      exit 后脚本自动获取热钱包地址给你确认."
echo "============================================================"
read -p ">>> 回车进入容器: " _
docker compose run --rm --no-deps -it api /bin/sh

# ============ [8] grant-ml-ops-permissions (自动获取热钱包地址 -> 确认 -> 执行) ============
echo ""
echo "=== [8] grant-ml-ops-permissions (冷钱包 -> 热钱包授权) ==="
echo "  自动获取热钱包地址 (warm keyring: $WARM_NAME) ..."
WARM_ADDR=$(echo "$KEYRING_PASSWORD" | ./inferenced keys show "$WARM_NAME" -a --keyring-backend file --keyring-dir /root/gonka/deploy/join/.inference 2>/dev/null | tr -d ' \n' || true)
case "$WARM_ADDR" in
  gonka1*) echo "  获取成功: $WARM_ADDR" ;;
  *)
    echo "  自动获取失败, 改为手动输入"
    while true; do
      read -p ">>> 输入热钱包地址 (gonka1...): " WARM_ADDR
      WARM_ADDR=$(echo "$WARM_ADDR" | tr -d ' ')
      case "$WARM_ADDR" in
        gonka1*) [ "${#WARM_ADDR}" -ge 39 ] && break ;;
      esac
      echo "  格式不对, 重输"
    done
    ;;
esac
echo ""
echo "  即将执行 grant:"
echo "    cold (from): $COLD_NAME"
echo "    warm (to):   $WARM_ADDR"
read -p ">>> 确认热钱包地址无误, 回车执行 grant (Ctrl+C 取消): " _
./inferenced tx inference grant-ml-ops-permissions \
  "$COLD_NAME" \
  "$WARM_ADDR" \
  --from "$COLD_NAME" \
  --keyring-backend file \
  --gas 2000000 \
  --node http://node1.gonka.ai:8000/chain-rpc/ \
  -y

# ============ [9] submit-new-participant (面板 IP = 本机) ============
echo ""
echo "=== [9] submit-new-participant (面板 IP http://$MYIP:8000) ==="
./inferenced tx inference submit-new-participant \
  "http://$MYIP:8000" \
  --from "$COLD_NAME" \
  --keyring-backend file \
  --unordered \
  --timeout-duration 1m \
  --node http://node1.gonka.ai:8000/chain-rpc/ \
  --chain-id gonka-mainnet

# ============ [10] 验证 (冷钱包地址) ============
echo ""
echo "=== [10] 5 秒后验证 participant ==="
sleep 5
while true; do
  read -p ">>> 输入冷钱包地址 (gonka1...): " COLD_ADDR
  COLD_ADDR=$(echo "$COLD_ADDR" | tr -d ' ')
  case "$COLD_ADDR" in
    gonka1*) [ "${#COLD_ADDR}" -ge 39 ] && break ;;
  esac
  echo "  格式不对, 重输"
done
./inferenced query inference show-participant "$COLD_ADDR" \
  --node http://node1.gonka.ai:8000/chain-rpc/

# ============ [11] restart api ============
echo ""
echo "=== [11] docker restart api ==="
docker restart api
echo ""
echo "============ 全部完成 ============"
