#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${RLB_REPO_URL:-https://github.com/suyi-92/reality-landing-bootstrap.git}"
INSTALL_DIR="${RLB_INSTALL_DIR:-/opt/reality-landing-bootstrap}"
DEFAULT_BRANCH="${RLB_BRANCH:-main}"
RUN_PHASES="${RLB_RUN_PHASES:-true}"
RLB_VERBOSE="${RLB_VERBOSE:-false}"
INSTALL_LOG_FILE="${RLB_INSTALL_LOG_FILE:-/tmp/reality-landing-bootstrap-install.log}"
export RLB_VERBOSE

if [[ -n "${RLB_INPUT_TTY:-}" ]]; then
  INPUT_TTY="$RLB_INPUT_TTY"
elif [[ -r /dev/tty ]]; then
  INPUT_TTY="/dev/tty"
elif [[ -t 0 ]]; then
  INPUT_TTY="/dev/stdin"
else
  echo "ERROR: 需要交互式终端来填写配置。" >&2
  exit 1
fi

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

line() { printf '%b\n' "${DIM}────────────────────────────────────────────────────────────${RESET}"; }
info() { printf '%b\n' "${CYAN}INFO${RESET} $*" >&2; }
warn() { printf '%b\n' "${YELLOW}WARN${RESET} $*" >&2; }
die() { printf '%b\n' "${RED}ERROR${RESET} $*" >&2; exit 1; }

clear_screen() {
  if [[ -t 1 ]]; then
    if command -v clear >/dev/null 2>&1; then
      clear 2>/dev/null || printf '\033[2J\033[H'
    else
      printf '\033[2J\033[H'
    fi
  fi
}

run_logged() {
  if [[ "$RLB_VERBOSE" == "true" ]]; then
    "$@"
  else
    "$@" >>"$INSTALL_LOG_FILE" 2>&1
  fi
}

banner() {
  clear_screen
  printf '%b\n' "${CYAN}${BOLD}"
  cat <<'EOF'
╭────────────────────────────────────────────────╮
│            Reality Landing Bootstrap           │
│        Xray VLESS + Reality landing VPS        │
╰────────────────────────────────────────────────╯
EOF
  printf '%b' "${RESET}"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash install.sh"

ensure_project() {
  local self_dir
  self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  if [[ -n "$self_dir" && -f "$self_dir/bootstrap.sh" && -f "$self_dir/config.example.env" ]]; then
    printf '%s\n' "$self_dir"
    return 0
  fi

  info "当前是一键远程执行模式，将项目安装到：$INSTALL_DIR"
  if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    info "安装 git/curl 基础依赖。"
    local apt_log="/tmp/reality-landing-bootstrap-install-apt.log"
    apt-get update -y >"$apt_log" 2>&1 || { tail -n 40 "$apt_log" >&2 || true; die "apt-get update 失败。"; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ca-certificates >>"$apt_log" 2>&1 || { tail -n 60 "$apt_log" >&2 || true; die "安装 git/curl 失败。"; }
  fi

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "检测到已有项目目录，拉取最新代码。"
    run_logged git -C "$INSTALL_DIR" fetch --all --prune
    run_logged git -C "$INSTALL_DIR" checkout "$DEFAULT_BRANCH"
    run_logged git -C "$INSTALL_DIR" pull --ff-only
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    run_logged git clone --branch "$DEFAULT_BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
  printf '%s\n' "$INSTALL_DIR"
}

read_default() {
  local prompt="$1" default_value="$2" value
  if [[ -n "$default_value" ]]; then
    if [[ "$INPUT_TTY" == "/dev/tty" || -t 0 ]]; then
      IFS= read -e -i "$default_value" -r -p "${prompt}: " value <"$INPUT_TTY" || true
    else
      printf '%b' "${BOLD}${prompt}${RESET} ${DIM}[默认: ${default_value}]${RESET}: " >"$INPUT_TTY"
      IFS= read -r value <"$INPUT_TTY" || true
      value="${value:-$default_value}"
    fi
  else
    printf '%b' "${BOLD}${prompt}${RESET}: " >"$INPUT_TTY"
    IFS= read -r value <"$INPUT_TTY" || true
  fi
  printf '%s\n' "$value"
}

read_bool() {
  local prompt="$1" default_value="$2" value
  while true; do
    value="$(read_default "$prompt" "$default_value")"
    case "$value" in
      true|false) printf '%s\n' "$value"; return 0 ;;
      y|Y|yes|YES|Yes) printf 'true\n'; return 0 ;;
      n|N|no|NO|No) printf 'false\n'; return 0 ;;
      *) warn "$prompt 必须是 true 或 false。" ;;
    esac
  done
}

shell_quote() { printf '%q' "$1"; }

csv_escape() {
  local value="$1"
  if [[ "$value" == *","* || "$value" == *"\""* || "$value" == *$'\n'* ]]; then
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
  else
    printf '%s' "$value"
  fi
}

public_ipv4() {
  curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true
}

collect_pubkeys() {
  local out="$1" index=1 key
  : >"$out"
  line
  printf '%b\n' "${CYAN}${BOLD}root SSH 公钥${RESET}"
  printf '%b\n' "${DIM}可以填写多个 ADMIN_PUBKEY；留空回车结束。${RESET}"
  while true; do
    key="$(read_default "ADMIN_PUBKEY #${index}" "")"
    if [[ -n "$key" ]]; then
      printf '%s\n' "$key" >>"$out"
    elif (( index > 1 )); then
      break
    else
      die "ADMIN_PUBKEY 不能为空；请至少粘贴一个本地 SSH 公钥。"
    fi
    index=$((index + 1))
  done
}

collect_clients() {
  local out="$1" index=1 more
  : >"$out"
  printf 'tag,listen_port,allowed_sources,uuid,server_name,flow\n' >"$out"
  line
  printf '%b\n' "${CYAN}${BOLD}中转鸡访问配置${RESET}"
  printf '%b\n' "${DIM}每一行会生成一个落地入口端口；allowed_sources 用分号分隔中转鸡 IP/CIDR。${RESET}"
  while true; do
    if (( index == 1 )); then
      more="true"
    else
      more="$(read_bool "是否继续添加第 ${index} 个中转鸡？" "false")"
    fi
    [[ "$more" == "true" ]] || break
    local tag listen_port allowed_sources client_uuid server_name flow
    tag="$(read_default "  tag" "relay-$(printf '%02d' "$index")")"
    listen_port="$(read_default "  listen_port (留空自动分配)" "")"
    allowed_sources="$(read_default "  allowed_sources" "")"
    client_uuid="$(read_default "  uuid (留空自动生成)" "")"
    server_name="$(read_default "  server_name (留空使用默认伪装域名)" "")"
    flow="$(read_default "  flow" "xtls-rprx-vision")"
    [[ -n "$allowed_sources" ]] || die "allowed_sources 不能为空。"
    printf '%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$tag")" \
      "$(csv_escape "$listen_port")" \
      "$(csv_escape "$allowed_sources")" \
      "$(csv_escape "$client_uuid")" \
      "$(csv_escape "$server_name")" \
      "$(csv_escape "$flow")" >>"$out"
    index=$((index + 1))
  done
}

write_config() {
  local pubkeys="$1"
  cat >config.env <<EOF
# Generated by install.sh. Sensitive values; do not publish.
SERVER_ALIAS=$(shell_quote "$server_alias")
SERVER_DOMAIN=$(shell_quote "$server_domain")
SERVER_IP_IPV4=$(shell_quote "$server_ip_ipv4")
SERVER_IP_IPV6=$(shell_quote "$server_ip_ipv6")
SSH_PORT=$(shell_quote "$ssh_port")
ADMIN_PUBKEY=$(shell_quote "$pubkeys")
ADMIN_PUBKEYS=""

REALITY_SERVER_NAME=$(shell_quote "$reality_server_name")
REALITY_DEST="${reality_server_name}:443"
CLIENT_PORT_START=$(shell_quote "$client_port_start")
EXTRA_PORT_START=$(shell_quote "$extra_port_start")
ENABLE_UFW=$(shell_quote "$enable_ufw")
ENABLE_FAIL2BAN=$(shell_quote "$enable_fail2ban")
ENABLE_IPV6_LISTEN=$(shell_quote "$enable_ipv6_listen")
RESET_REALITY_KEYS=$(shell_quote "$reset_reality_keys")
RESET_CLIENT_UUIDS=$(shell_quote "$reset_client_uuids")

RLB_STATE_DIR="/etc/reality-landing-bootstrap"
XRAY_CONFIG_PATH="/etc/xray/config.json"
LANDING_CLIENTS_PATH="./landing-clients.csv"
CLIENT_UUIDS_PATH="/etc/reality-landing-bootstrap/client-uuids.json"
REALITY_PRIVATE_KEY_PATH="/etc/reality-landing-bootstrap/reality-private.key"
REALITY_PUBLIC_KEY_PATH="/etc/reality-landing-bootstrap/reality-public.key"
REALITY_SHORT_ID_PATH="/etc/reality-landing-bootstrap/reality-short-id.txt"
LINKS_DIR="/etc/reality-landing-bootstrap/links"
LINKS_OUT="/root/reality-landing-bootstrap-links.txt"
CLIENT_FINGERPRINT="chrome"
DEFAULT_FLOW="xtls-rprx-vision"
XRAY_LOGLEVEL="warning"
EOF
  chmod 600 config.env
}

run_flow() {
  line
  printf '%b\n' "${GREEN}${BOLD}配置文件已生成：${RESET}"
  printf '  %s\n' "$PROJECT_DIR/config.env" "$PROJECT_DIR/landing-clients.csv"
  if [[ "$RUN_PHASES" != "true" ]]; then
    warn "RLB_RUN_PHASES=$RUN_PHASES，仅生成配置，不执行部署阶段。"
    return 0
  fi
  bash bootstrap.sh --phase preflight
  bash bootstrap.sh --phase ssh-phase1
  line
  printf '%b\n' "${YELLOW}${BOLD}安全确认：不要关闭当前 SSH 窗口。${RESET}"
  printf '请另开一个终端确认 root 公钥登录成功：\n'
  local host="$server_domain"
  [[ -n "$host" ]] || host="$server_ip_ipv4"
  [[ -n "$host" ]] || host="$server_ip_ipv6"
  printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@%s\n' "$ssh_port" "$host"
  printf '  whoami\n\n'
  if [[ "$(read_bool "我已确认 root 公钥登录正常，继续 SSH final 加固？" "false")" == "true" ]]; then
    CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
  else
    warn "已暂停在 ssh-phase1。之后可手动执行：sudo CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final"
    return 0
  fi
  bash bootstrap.sh --phase fail2ban
  bash bootstrap.sh --phase xray
  bash bootstrap.sh --phase firewall
  bash bootstrap.sh --phase validate
  bash bootstrap.sh --phase output-links
  line
  printf '%b\n' "${GREEN}${BOLD}部署完成。链接文件：${RESET}"
  printf '  sudo cat /root/reality-landing-bootstrap-links.txt\n'
}

banner
PROJECT_DIR="$(ensure_project)"
cd "$PROJECT_DIR"

line
printf '%b\n' "${CYAN}${BOLD}基础信息${RESET}"
default_ip="$(public_ipv4)"
server_alias="$(read_default "SERVER_ALIAS" "")"
server_domain="$(read_default "SERVER_DOMAIN" "")"
server_ip_ipv4="$(read_default "SERVER_IP_IPV4" "$default_ip")"
server_ip_ipv6="$(read_default "SERVER_IP_IPV6" "")"
ssh_port="$(read_default "SSH_PORT" "22")"
reality_server_name="$(read_default "REALITY_SERVER_NAME" "www.microsoft.com")"
client_port_start="$(read_default "CLIENT_PORT_START" "443")"
extra_port_start="$(read_default "EXTRA_PORT_START" "51043")"
enable_ipv6_listen="$(read_bool "ENABLE_IPV6_LISTEN" "$([[ -n "$server_ip_ipv6" ]] && echo true || echo false)")"
enable_ufw="$(read_bool "ENABLE_UFW" "true")"
enable_fail2ban="$(read_bool "ENABLE_FAIL2BAN" "true")"
reset_reality_keys="$(read_bool "RESET_REALITY_KEYS" "false")"
reset_client_uuids="$(read_bool "RESET_CLIENT_UUIDS" "false")"

[[ -n "$server_alias" ]] || die "SERVER_ALIAS 不能为空。"
[[ -n "$server_domain" || -n "$server_ip_ipv4" || -n "$server_ip_ipv6" ]] || die "SERVER_DOMAIN/SERVER_IP_IPV4/SERVER_IP_IPV6 至少填写一个。"

keys_file="$(mktemp)"
clients_file="$(mktemp)"
trap 'rm -f "$keys_file" "$clients_file"' EXIT
collect_pubkeys "$keys_file"
collect_clients "$clients_file"
write_config "$(cat "$keys_file")"
cp "$clients_file" landing-clients.csv
chmod 600 landing-clients.csv
run_flow
