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

port_listening() {
  local port="$1"
  ss -H -ltn | awk -v port="$port" '
    {
      local_addr = $4
      if (local_addr ~ ":" port "$") {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

wait_for_port() {
  local port="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if port_listening "$port"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

dump_xray_diagnostics() {
  {
    printf '\n===== xray diagnostics =====\n'
    date '+%F %T'
    printf '\n--- systemctl status xray ---\n'
    systemctl status xray --no-pager -l || true
    printf '\n--- journalctl -u xray -n 120 ---\n'
    journalctl -u xray -n 120 --no-pager || true
    printf '\n--- ss -H -ltnp ---\n'
    ss -H -ltnp || true
    printf '===== end xray diagnostics =====\n'
  } >>"$LOG_FILE" 2>&1
}

tcp_url_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    printf '[%s]\n' "$host"
  else
    printf '%s\n' "$host"
  fi
}

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
    if wait_for_port "$port"; then
      info "端口监听正常：$port"
    else
      dump_xray_diagnostics
      die "端口未监听：$port；详细诊断已写入 $LOG_FILE"
    fi
  done
fi

cat <<EOF

验证完成。建议在中转鸡 Debian/Linux 上测试：
$(for host in $(server_hosts); do
  for port in "${PORTS[@]}"; do
    printf '  curl -v --connect-timeout 5 --max-time 5 telnet://%s:%s </dev/null\n' "$(tcp_url_host "$host")" "$port"
  done
done)
EOF
