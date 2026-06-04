#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="xray-install"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

apt_install ca-certificates curl unzip openssl python3

install_xray_if_needed() {
  if [[ -n "$(xray_bin)" ]]; then
    info "Xray 已安装：$(xray_bin)"
    return 0
  fi
  if is_dry_run; then
    log "DRY-RUN: install Xray official release"
    return 0
  fi
  info "使用 XTLS 官方安装脚本安装 Xray。"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >>"$LOG_FILE" 2>&1
  [[ -n "$(xray_bin)" ]] || die "Xray 安装后仍找不到 xray 可执行文件。"
}

x25519_output_field() {
  local output="$1" wanted="$2"
  printf '%s\n' "$output" | python3 -c '
import re
import sys

wanted = sys.argv[1]
text = sys.stdin.read()
pattern = re.compile(r"(Private\s*key|Public\s*key|PrivateKey|PublicKey|Password|Hash32)\s*:\s*", re.I)
matches = list(pattern.finditer(text))
fields = {}
for index, match in enumerate(matches):
    raw_key = re.sub(r"[\s_-]+", "", match.group(1).lower())
    start = match.end()
    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
    raw_value = text[start:end].strip()
    value = raw_value.split()[0].strip(chr(34) + chr(39)) if raw_value else ""
    if value and raw_key not in fields:
        fields[raw_key] = value

if wanted == "private":
    print(fields.get("privatekey", ""))
elif wanted == "public":
    print(fields.get("publickey") or fields.get("password", ""))
' "$wanted"
}

log_redacted_x25519_output() {
  local output="$1" line key
  log "xray x25519 输出脱敏摘要："
  while IFS= read -r line; do
    if [[ "$line" == *:* ]]; then
      key="${line%%:*}"
      log "  ${key}: <redacted>"
    elif [[ -n "$line" ]]; then
      log "  $line"
    fi
  done <<<"$output"
}

ensure_reality_keys() {
  local bin output private public
  bin="$(xray_bin)"
  mkdir -p "$RLB_STATE_DIR"
  if [[ "$RESET_REALITY_KEYS" == "true" || ! -s "$REALITY_PRIVATE_KEY_PATH" || ! -s "$REALITY_PUBLIC_KEY_PATH" ]]; then
    if is_dry_run; then
      log "DRY-RUN: xray x25519 > Reality keypair"
    else
      if ! output="$("$bin" x25519 2>&1)"; then
        log_redacted_x25519_output "$output"
        die "xray x25519 执行失败。"
      fi
      private="$(x25519_output_field "$output" private)"
      public="$(x25519_output_field "$output" public)"
      if [[ -z "$private" || -z "$public" ]]; then
        log_redacted_x25519_output "$output"
        die "xray x25519 输出无法解析；已兼容 Private key/Public key 和 PrivateKey/Password 格式。"
      fi
      umask 077
      printf '%s\n' "$private" >"$REALITY_PRIVATE_KEY_PATH"
      printf '%s\n' "$public" >"$REALITY_PUBLIC_KEY_PATH"
    fi
  fi
  if [[ "$RESET_REALITY_KEYS" == "true" || ! -s "$REALITY_SHORT_ID_PATH" ]]; then
    if is_dry_run; then
      log "DRY-RUN: openssl rand -hex 8 > Reality short-id"
    else
      umask 077
      openssl rand -hex 8 >"$REALITY_SHORT_ID_PATH"
    fi
  fi
  if ! is_dry_run; then
    chmod 600 "$REALITY_PRIVATE_KEY_PATH" "$REALITY_PUBLIC_KEY_PATH" "$REALITY_SHORT_ID_PATH"
  fi
}

write_xray_service() {
  local bin
  bin="$(xray_bin)"
  write_root_file /etc/systemd/system/xray.service 0644 <<EOF
[Unit]
Description=Xray Service managed by reality-landing-bootstrap
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$bin run -config $XRAY_CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
}

install_xray_if_needed
ensure_reality_keys
write_xray_service

if ! is_dry_run; then
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
fi

info "Xray 安装和 Reality 密钥材料准备完成。"
