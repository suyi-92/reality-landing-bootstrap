#!/usr/bin/env bash
set -Eeuo pipefail

RLB_PROJECT_DIR="${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
RLB_CONFIG_FILE="${RLB_CONFIG_FILE:-$RLB_PROJECT_DIR/config.env}"
RLB_DRY_RUN="${RLB_DRY_RUN:-false}"
RLB_VERBOSE="${RLB_VERBOSE:-false}"
SCRIPT_DIR="$RLB_PROJECT_DIR/scripts"
LOG_FILE="/var/log/reality-landing-bootstrap.log"
BACKUP_ROOT="/root/reality-landing-bootstrap-backups"
export RLB_PROJECT_DIR RLB_CONFIG_FILE RLB_DRY_RUN RLB_VERBOSE

if [[ $EUID -eq 0 ]]; then
  touch "$LOG_FILE" 2>/dev/null || true
fi

trap 'rc=$?; echo "[ERROR] line=${LINENO} cmd=${BASH_COMMAND} rc=${rc}" >&2; exit $rc' ERR

_ts() { date '+%F %T'; }
log() {
  local line
  line="[$(_ts)] $*"
  printf '%s\n' "$line" >>"$LOG_FILE"
  if [[ "$RLB_VERBOSE" == "true" ]]; then
    printf '%s\n' "$line" >&2
  fi
}
info() { log "INFO: $*"; }
warn() {
  local line
  line="[$(_ts)] WARN: $*"
  printf '%s\n' "$line" >>"$LOG_FILE"
  printf '%s\n' "$line" >&2
}
die() {
  local line
  line="[$(_ts)] ERROR: $*"
  printf '%s\n' "$line" >>"$LOG_FILE"
  printf '%s\n' "$line" >&2
  exit 1
}

is_dry_run() { [[ "$RLB_DRY_RUN" == "true" ]]; }
require_root() { [[ $EUID -eq 0 ]] || die "必须以 root 运行：sudo bash bootstrap.sh ..."; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if is_dry_run; then
    log "DRY-RUN: $*"
  else
    log "+ $*"
    if [[ "$RLB_VERBOSE" == "true" ]]; then
      "$@" 2>&1 | tee -a "$LOG_FILE"
    else
      "$@" >>"$LOG_FILE" 2>&1
    fi
  fi
}

apt_install() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  if is_dry_run; then
    log "DRY-RUN: apt-get update && apt-get install -y $*"
  else
    info "安装/确认依赖：$*"
    apt-get update >>"$LOG_FILE" 2>&1
    apt-get install -y "$@" >>"$LOG_FILE" 2>&1
  fi
}

user_home() {
  local user="$1" entry home
  entry="$(getent passwd "$user" || true)"
  if [[ -n "$entry" ]]; then
    IFS=: read -r _ _ _ _ _ home _ <<<"$entry"
    [[ -n "$home" ]] || die "无法获取 $user 的 home"
    printf '%s\n' "$home"
    return 0
  fi
  [[ "$user" == "root" ]] && { printf '/root\n'; return 0; }
  printf '/home/%s\n' "$user"
}

load_config() {
  [[ -f "$RLB_CONFIG_FILE" ]] || die "找不到配置文件：$RLB_CONFIG_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$RLB_CONFIG_FILE"
  set +a

  : "${SERVER_ALIAS:=landing-vps}"
  : "${SERVER_DOMAIN:=}"
  : "${SERVER_IP_IPV4:=}"
  : "${SERVER_IP_IPV6:=}"
  : "${SSH_PORT:=22}"
  : "${ADMIN_PUBKEY:=}"
  : "${ADMIN_PUBKEYS:=}"
  if [[ -n "$ADMIN_PUBKEYS" ]]; then
    if [[ -n "$ADMIN_PUBKEY" ]]; then
      ADMIN_PUBKEY+=$'\n'
      ADMIN_PUBKEY+="$ADMIN_PUBKEYS"
    else
      ADMIN_PUBKEY="$ADMIN_PUBKEYS"
    fi
  fi
  export ADMIN_PUBKEY ADMIN_PUBKEYS

  : "${REALITY_SERVER_NAME:=www.microsoft.com}"
  : "${REALITY_DEST:=www.microsoft.com:443}"
  : "${CLIENT_PORT_START:=443}"
  : "${EXTRA_PORT_START:=51043}"
  : "${ENABLE_UFW:=true}"
  : "${ENABLE_FAIL2BAN:=true}"
  : "${ENABLE_IPV6_LISTEN:=false}"
  : "${RESET_REALITY_KEYS:=false}"
  : "${RESET_CLIENT_UUIDS:=false}"
  : "${RLB_STATE_DIR:=/etc/reality-landing-bootstrap}"
  : "${XRAY_CONFIG_PATH:=/etc/xray/config.json}"
  : "${LANDING_CLIENTS_PATH:=./landing-clients.csv}"
  : "${CLIENT_UUIDS_PATH:=$RLB_STATE_DIR/client-uuids.json}"
  : "${REALITY_PRIVATE_KEY_PATH:=$RLB_STATE_DIR/reality-private.key}"
  : "${REALITY_PUBLIC_KEY_PATH:=$RLB_STATE_DIR/reality-public.key}"
  : "${REALITY_SHORT_ID_PATH:=$RLB_STATE_DIR/reality-short-id.txt}"
  : "${LINKS_DIR:=$RLB_STATE_DIR/links}"
  : "${LINKS_OUT:=/root/reality-landing-bootstrap-links.txt}"
  : "${CLIENT_FINGERPRINT:=chrome}"
  : "${DEFAULT_FLOW:=xtls-rprx-vision}"
  : "${XRAY_LOGLEVEL:=warning}"

  validate_config_basics
}

validate_bool() {
  local name="$1" value="${!1}"
  [[ "$value" == "true" || "$value" == "false" ]] || die "$name 必须是 true 或 false，当前：$value"
}

validate_port() {
  local name="$1" value="${!1}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字端口，当前：$value"
  (( value >= 1 && value <= 65535 )) || die "$name 超出端口范围 1-65535：$value"
}

validate_config_basics() {
  [[ -n "$SERVER_ALIAS" ]] || die "SERVER_ALIAS 不能为空"
  [[ -n "$SERVER_DOMAIN" || -n "$SERVER_IP_IPV4" || -n "$SERVER_IP_IPV6" ]] || die "SERVER_DOMAIN/SERVER_IP_IPV4/SERVER_IP_IPV6 至少填写一个"
  validate_port SSH_PORT
  validate_port CLIENT_PORT_START
  validate_port EXTRA_PORT_START
  validate_bool ENABLE_UFW
  validate_bool ENABLE_FAIL2BAN
  validate_bool ENABLE_IPV6_LISTEN
  validate_bool RESET_REALITY_KEYS
  validate_bool RESET_CLIENT_UUIDS
  [[ "$RLB_STATE_DIR" == /* ]] || die "RLB_STATE_DIR 必须是绝对路径"
  [[ "$XRAY_CONFIG_PATH" == /* ]] || die "XRAY_CONFIG_PATH 必须是绝对路径"
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) info "系统受支持：${PRETTY_NAME:-$ID $VERSION_ID}" ;;
    *) die "当前系统未列入默认支持范围：${PRETTY_NAME:-unknown}；支持 Ubuntu 22.04/24.04、Debian 12/13。" ;;
  esac
}

backup_path() {
  local path="$1" stamp dest
  [[ -e "$path" ]] || return 0
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="$BACKUP_ROOT/backup-${stamp}-${PHASE_NAME}/${path#/}"
  if is_dry_run; then
    log "DRY-RUN: backup $path -> $dest"
  else
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
    info "已备份：$path -> $dest"
  fi
}

sshd_bin() {
  if [[ -x /usr/sbin/sshd ]]; then printf '/usr/sbin/sshd\n'; else command -v sshd; fi
}

ssh_service_name() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then printf 'ssh\n'; else printf 'sshd\n'; fi
}

ensure_sshd_dropin_include() {
  local conf="/etc/ssh/sshd_config"
  [[ -f "$conf" ]] || die "找不到 $conf"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$conf"; then
    return 0
  fi
  backup_path "$conf"
  if is_dry_run; then
    log "DRY-RUN: prepend Include to $conf"
  else
    local tmp
    tmp="$(mktemp)"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$tmp"
    cat "$conf" >>"$tmp"
    cat "$tmp" >"$conf"
    rm -f "$tmp"
  fi
}

test_sshd_config() {
  local bin
  bin="$(sshd_bin)"
  run "$bin" -t
}

reload_ssh() {
  local svc
  svc="$(ssh_service_name)"
  if is_dry_run; then
    log "DRY-RUN: systemctl reload $svc"
  else
    systemctl reload "$svc" >>"$LOG_FILE" 2>&1 || systemctl restart "$svc" >>"$LOG_FILE" 2>&1
    info "SSH 服务已重载：$svc"
  fi
}

write_root_file() {
  local path="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if is_dry_run; then
    log "DRY-RUN: install -m $mode $path"
    rm -f "$tmp"
  else
    mkdir -p "$(dirname "$path")"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
  fi
}

xray_bin() {
  if [[ -x /usr/local/bin/xray ]]; then printf '/usr/local/bin/xray\n'; return 0; fi
  if [[ -x /usr/bin/xray ]]; then printf '/usr/bin/xray\n'; return 0; fi
  command -v xray 2>/dev/null || true
}

server_hosts() {
  if [[ -n "$SERVER_DOMAIN" ]]; then
    printf '%s\n' "$SERVER_DOMAIN"
  elif [[ -n "$SERVER_IP_IPV4" ]]; then
    printf '%s\n' "$SERVER_IP_IPV4"
  elif [[ -n "$SERVER_IP_IPV6" ]]; then
    printf '%s\n' "$SERVER_IP_IPV6"
  else
    printf '服务器IP\n'
  fi
}
