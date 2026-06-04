#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="preflight"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

apt_install ca-certificates curl gnupg lsb-release openssl python3 sudo openssh-server iproute2
have systemctl || die "找不到 systemctl；本项目仅支持 systemd 环境。"
have ss || die "找不到 ss；请确认 iproute2 已安装。"

backup_path /etc/ssh/sshd_config
[[ -d /etc/ssh/sshd_config.d ]] && backup_path /etc/ssh/sshd_config.d
ensure_sshd_dropin_include
test_sshd_config

if [[ -z "$ADMIN_PUBKEY" && ! -s /root/.ssh/authorized_keys ]]; then
  die "ADMIN_PUBKEY/ADMIN_PUBKEYS 为空，且 /root/.ssh/authorized_keys 不存在或为空。"
fi

python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --check-only --quiet

cat <<EOF

Preflight 通过。建议下一步：
  sudo bash bootstrap.sh --phase ssh-phase1

ssh-phase1 只会准备 root 公钥登录，不会禁用 root/密码。
EOF
