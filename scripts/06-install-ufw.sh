#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="ufw"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if [[ "$ENABLE_UFW" != "true" ]]; then
  info "ENABLE_UFW=false，跳过 UFW。"
  exit 0
fi

backup_path /etc/ufw || true
apt_install ufw
run ufw allow "${SSH_PORT}/tcp" comment "reality-landing-bootstrap SSH current port"
info "已先放行当前 SSH 端口 $SSH_PORT/tcp。"
