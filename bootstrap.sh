#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$PROJECT_DIR/scripts"
export RLB_PROJECT_DIR="$PROJECT_DIR"

PHASE=""
RLB_CONFIG_FILE="$PROJECT_DIR/config.env"
RLB_DRY_RUN="false"
RLB_VERBOSE="${RLB_VERBOSE:-false}"
export RLB_CONFIG_FILE RLB_DRY_RUN RLB_VERBOSE

usage() {
  cat <<'EOF'
Usage: sudo bash bootstrap.sh --phase <phase> [--config config.env] [--dry-run] [--verbose]

Phases:
  preflight       检查系统、配置、SSH 和客户端 CSV
  ssh-phase1      准备 root SSH 公钥登录，不禁 root/密码
  ssh-final       root 仅允许公钥登录；必须 CONFIRM_ROOT_KEY_LOGIN=yes
  fail2ban        安装并配置 fail2ban
  xray            安装 Xray，生成 VLESS+Reality 多入口配置并重启
  firewall        按 landing-clients.csv 精确放行来源 IP 到端口
  validate        验证 SSH、fail2ban、UFW、Xray 配置/服务/端口
  output-links    生成每个中转鸡专属 vless:// 链接文件
  rollback        回滚本项目 SSH hardening、Xray 服务和 UFW 项目规则
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:-}"; shift 2 ;;
    --config) RLB_CONFIG_FILE="${2:-}"; export RLB_CONFIG_FILE; shift 2 ;;
    --dry-run) RLB_DRY_RUN="true"; export RLB_DRY_RUN; shift ;;
    --verbose) RLB_VERBOSE="true"; export RLB_VERBOSE; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$PHASE" ]] || { usage >&2; exit 2; }

run_phase() {
  bash "$SCRIPT_DIR/$1"
}

case "$PHASE" in
  preflight) run_phase 01-preflight.sh ;;
  ssh-phase1)
    run_phase 02-setup-root-ssh.sh
    run_phase 03-ssh-hardening-phase1.sh
    ;;
  ssh-final) run_phase 04-ssh-hardening-final.sh ;;
  fail2ban) run_phase 05-install-fail2ban.sh ;;
  xray)
    run_phase 07-install-xray.sh
    python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --write --quiet
    run_phase 10-validate.sh
    ;;
  firewall) run_phase 09-apply-firewall.sh ;;
  validate) run_phase 10-validate.sh ;;
  output-links) python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --output-links ;;
  rollback) run_phase 12-rollback.sh ;;
  *) echo "Unknown phase: $PHASE" >&2; usage >&2; exit 2 ;;
esac
