#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="fail2ban"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
  info "ENABLE_FAIL2BAN=false，跳过 fail2ban。"
  exit 0
fi

backup_path /etc/fail2ban || true
apt_install fail2ban

write_root_file /etc/fail2ban/jail.d/reality-landing-bootstrap-sshd.local 0644 <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
EOF

if ! is_dry_run; then
  fail2ban-client -t >>"$LOG_FILE" 2>&1
  systemctl enable fail2ban >>"$LOG_FILE" 2>&1
  systemctl restart fail2ban >>"$LOG_FILE" 2>&1
  systemctl is-active --quiet fail2ban || die "fail2ban 未运行"
  info "fail2ban 服务已启动。"
fi
