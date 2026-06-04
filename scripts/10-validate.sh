#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="validate"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

mapfile -t PORTS < <(python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --print-ports)
[[ "${#PORTS[@]}" -ge 1 ]] || die "未解析到 Xray 入口端口。"

info "检查 sshd 配置语法。"
test_sshd_config

if [[ "$ENABLE_FAIL2BAN" == "true" ]] && ! is_dry_run; then
  systemctl is-active --quiet fail2ban || die "fail2ban 未运行"
fi

bin="$(xray_bin)"
[[ -n "$bin" ]] || die "找不到 xray 可执行文件。"

info "检查 Xray 配置语法。"
run "$bin" run -test -config "$XRAY_CONFIG_PATH"

if ! is_dry_run; then
  systemctl enable xray >>"$LOG_FILE" 2>&1
  systemctl restart xray >>"$LOG_FILE" 2>&1
  sleep 1
  systemctl is-active --quiet xray || die "Xray 服务未运行"
fi

if ! is_dry_run; then
  for port in "${PORTS[@]}"; do
    if ss -ltn "( sport = :$port )" | awk 'NR>1 {found=1} END{exit found?0:1}'; then
      info "端口监听正常：$port"
    else
      die "端口未监听：$port"
    fi
  done
fi

cat <<EOF

验证完成。建议从中转鸡测试：
$(for host in $(server_hosts); do
  for port in "${PORTS[@]}"; do
    printf '  Test-NetConnection %s -Port %s\n' "$host" "$port"
  done
done)
EOF
