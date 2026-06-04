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
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
pattern = re.compile(r"(Private\s*key|Public\s*key|PrivateKey|PublicKey|Password(?:\s*\([^)]*\))?|Hash32)\s*:\s*", re.I)
matches = list(pattern.finditer(text))
fields = {}
for index, match in enumerate(matches):
    raw_key = re.sub(r"[^a-z0-9]+", "", match.group(1).lower())
    start = match.end()
    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
    raw_value = text[start:end].strip()
    value = raw_value.split()[0].strip(chr(34) + chr(39)) if raw_value else ""
    if value and raw_key not in fields:
        fields[raw_key] = value

def first_key(*prefixes):
    for key, value in fields.items():
        if any(key.startswith(prefix) for prefix in prefixes):
            return value
    return ""

if wanted == "private":
    print(first_key("privatekey"))
elif wanted == "public":
    print(first_key("publickey", "password"))
' "$wanted"
}

derive_xray_public_key() {
  local private="$1" bin output public
  bin="$(xray_bin)"
  if ! output="$("$bin" x25519 -i "$private" 2>&1)"; then
    log_redacted_x25519_output "$output"
    return 1
  fi
  public="$(x25519_output_field "$output" public)"
  if [[ -z "$public" ]]; then
    log_redacted_x25519_output "$output"
    return 1
  fi
  printf '%s\n' "$public"
}

hex_to_base64url() {
  local hex="$1"
  python3 -c '
import base64
import sys

raw = bytes.fromhex(sys.argv[1])
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
' "$hex"
}

openssl_x25519_keypair() {
  local key_file text private_hex public_hex private public
  key_file="$(mktemp)"
  if ! openssl genpkey -algorithm X25519 -out "$key_file" >>"$LOG_FILE" 2>&1; then
    rm -f "$key_file"
    return 1
  fi
  if ! text="$(openssl pkey -in "$key_file" -text -noout 2>>"$LOG_FILE")"; then
    rm -f "$key_file"
    return 1
  fi
  rm -f "$key_file"
  private_hex="$(printf '%s\n' "$text" | awk '
    /^[[:space:]]*priv:/ { section = "private"; next }
    /^[[:space:]]*pub:/ { section = "public"; next }
    /^[[:space:]]*[0-9a-fA-F][0-9a-fA-F](:[0-9a-fA-F][0-9a-fA-F])+/ {
      line = $0
      gsub(/[[:space:]:]/, "", line)
      if (section == "private") private = private line
      if (section == "public") public = public line
    }
    END { print private }
  ')"
  public_hex="$(printf '%s\n' "$text" | awk '
    /^[[:space:]]*priv:/ { section = "private"; next }
    /^[[:space:]]*pub:/ { section = "public"; next }
    /^[[:space:]]*[0-9a-fA-F][0-9a-fA-F](:[0-9a-fA-F][0-9a-fA-F])+/ {
      line = $0
      gsub(/[[:space:]:]/, "", line)
      if (section == "private") private = private line
      if (section == "public") public = public line
    }
    END { print public }
  ')"
  [[ ${#private_hex} -eq 64 && ${#public_hex} -eq 64 ]] || return 1
  private="$(hex_to_base64url "$private_hex")"
  public="$(hex_to_base64url "$public_hex")"
  [[ -n "$private" && -n "$public" ]] || return 1
  printf '%s\n%s\n' "$private" "$public"
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
  local bin output private public current_public derived_public
  local -a keypair
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
        info "xray x25519 输出无法解析，改用 OpenSSL 生成 X25519 keypair。"
        if ! mapfile -t keypair < <(openssl_x25519_keypair); then
          die "xray x25519 输出无法解析，且 OpenSSL X25519 keypair 生成失败。"
        fi
        private="${keypair[0]:-}"
        public="${keypair[1]:-}"
        [[ -n "$private" && -n "$public" ]] || die "OpenSSL X25519 keypair 输出无法解析。"
      fi
      if derived_public="$(derive_xray_public_key "$private")"; then
        public="$derived_public"
      else
        warn "无法用 Xray 从 Reality private key 推导 public key，将使用已生成的 public key。"
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
    private="$(<"$REALITY_PRIVATE_KEY_PATH")"
    if derived_public="$(derive_xray_public_key "$private")"; then
      current_public="$(cat "$REALITY_PUBLIC_KEY_PATH" 2>/dev/null || true)"
      if [[ "$current_public" != "$derived_public" ]]; then
        info "Reality public key 与 private key 不一致，已按 private key 重新校准。"
        umask 077
        printf '%s\n' "$derived_public" >"$REALITY_PUBLIC_KEY_PATH"
      fi
    else
      warn "无法校验 Reality public key 与 private key 是否匹配。"
    fi
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
  write_root_file /etc/systemd/system/xray.service.d/99-reality-landing-bootstrap.conf 0644 <<EOF
[Service]
User=root
ExecStart=
ExecStart=$bin run -config $XRAY_CONFIG_PATH
EOF
}

install_xray_if_needed
ensure_reality_keys
write_xray_service

if ! is_dry_run; then
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
fi

info "Xray 安装和 Reality 密钥材料准备完成。"
