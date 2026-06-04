#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="rollback"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config

[[ "${CONFIRM_ROLLBACK:-}" == "yes" ]] || die "拒绝回滚：请设置 CONFIRM_ROLLBACK=yes。"

if is_dry_run; then
  log "DRY-RUN: remove SSH hardening drop-in and reload ssh"
else
  rm -f /etc/ssh/sshd_config.d/00-reality-landing-bootstrap-hardening.conf
  reload_ssh
fi

if command -v ufw >/dev/null 2>&1; then
  stale_file="$(mktemp)"
  ufw status numbered 2>/dev/null |
    awk '/reality-landing-bootstrap/ {
      line = $0
      sub(/^\[[[:space:]]*/, "", line)
      sub(/\].*/, "", line)
      if (line ~ /^[0-9]+$/) print line
    }' |
    sort -rn -u >"$stale_file"
  while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    run ufw --force delete "$number"
  done <"$stale_file"
  rm -f "$stale_file"
fi

if systemctl list-unit-files xray.service >/dev/null 2>&1; then
  run systemctl stop xray
fi

cat <<EOF

回滚完成：
  - 已移除本项目 SSH hardening drop-in。
  - 已删除带 reality-landing-bootstrap 注释的 UFW 规则。
  - 已停止 xray 服务。
EOF
