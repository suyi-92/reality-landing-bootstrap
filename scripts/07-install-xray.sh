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

ensure_reality_keys() {
  local bin output private public
  bin="$(xray_bin)"
  mkdir -p "$RLB_STATE_DIR"
  if [[ "$RESET_REALITY_KEYS" == "true" || ! -s "$REALITY_PRIVATE_KEY_PATH" || ! -s "$REALITY_PUBLIC_KEY_PATH" ]]; then
    if is_dry_run; then
      log "DRY-RUN: xray x25519 > Reality keypair"
    else
      output="$("$bin" x25519)"
      private="$(awk -F': ' '/Private key:/ {print $2}' <<<"$output")"
      public="$(awk -F': ' '/Public key:/ {print $2}' <<<"$output")"
      [[ -n "$private" && -n "$public" ]] || die "xray x25519 输出无法解析。"
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
