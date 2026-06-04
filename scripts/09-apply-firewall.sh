#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="firewall"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

if [[ "$ENABLE_UFW" != "true" ]]; then
  info "ENABLE_UFW=false，跳过防火墙配置。"
  exit 0
fi

bash "$SCRIPT_DIR/06-install-ufw.sh"

cleanup_project_rules() {
  local stale_file number
  stale_file="$(mktemp)"
  if command -v ufw >/dev/null 2>&1; then
    ufw status numbered 2>/dev/null | python3 - >"$stale_file" <<'PY'
import re
import sys
nums = []
for line in sys.stdin:
    if "reality-landing-bootstrap" not in line:
        continue
    match = re.search(r"^\[\s*(\d+)\]", line)
    if match:
        nums.append(int(match.group(1)))
for num in sorted(set(nums), reverse=True):
    print(num)
PY
  fi
  if [[ -s "$stale_file" ]]; then
    info "清理旧的本项目 UFW 规则。"
    while IFS= read -r number; do
      [[ -n "$number" ]] || continue
      run ufw --force delete "$number"
    done <"$stale_file"
  fi
  rm -f "$stale_file"
}

cleanup_project_rules
run ufw allow "${SSH_PORT}/tcp" comment "reality-landing-bootstrap SSH current port"

while IFS=$'\t' read -r tag port source; do
  [[ -n "$tag" && -n "$port" && -n "$source" ]] || continue
  run ufw allow from "$source" to any port "$port" proto tcp comment "reality-landing-bootstrap $tag $port"
done < <(python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --print-ufw-rules)

if is_dry_run; then
  log "DRY-RUN: ufw --force enable"
else
  ufw --force enable >>"$LOG_FILE" 2>&1
  ufw status verbose >>"$LOG_FILE" 2>&1
fi

cat <<EOF

UFW 已按 landing-clients.csv 精确开放。服务商安全组也需要放行：
  SSH: tcp/$SSH_PORT
$(python3 "$SCRIPT_DIR/08-generate-xray-config.py" --config-env "$RLB_CONFIG_FILE" --print-ufw-rules | awk -F '\t' '{ printf "  %s: tcp/%s from %s\n", $1, $2, $3 }')
EOF
