#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="setup-root-ssh"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

apt_install openssh-server

get_pubkey_for_root() {
  if [[ -n "$ADMIN_PUBKEY" ]]; then
    printf '%s\n' "$ADMIN_PUBKEY"
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    cat /root/.ssh/authorized_keys
  else
    return 1
  fi
}

validate_pubkey_text() {
  local key_file="$1"
  awk 'NF && $1 !~ /^#/ { if ($1 !~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/) exit 1 }' "$key_file"
}

install_authorized_keys() {
  local key_text="$1" home tmp
  home="$(user_home root)"
  if is_dry_run; then
    log "DRY-RUN: install authorized_keys for root"
    return 0
  fi
  install -d -m 700 -o root -g root "$home/.ssh"
  tmp="$(mktemp)"
  printf '%s\n' "$key_text" | awk 'NF && $1 !~ /^#/' >"$tmp"
  validate_pubkey_text "$tmp" || { rm -f "$tmp"; die "root 的 SSH 公钥格式不正确"; }
  touch "$home/.ssh/authorized_keys"
  chown root:root "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qxF "$line" "$home/.ssh/authorized_keys" || printf '%s\n' "$line" >>"$home/.ssh/authorized_keys"
  done <"$tmp"
  rm -f "$tmp"
  chown -R root:root "$home/.ssh"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"
  chmod go-w "$home" || true
}

root_keys="$(get_pubkey_for_root || true)"
[[ -n "$root_keys" ]] || die "没有可用 ADMIN_PUBKEY，也无法从 /root/.ssh/authorized_keys 复制。"
install_authorized_keys "$root_keys"

cat <<EOF

root SSH 公钥准备完成。

下一步会写入 phase1 SSH drop-in，只开启公钥登录，不禁 root/密码。
EOF
