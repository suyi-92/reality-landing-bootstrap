#!/usr/bin/env bash
set -Eeuo pipefail
PHASE_NAME="ssh-final"
source "${RLB_PROJECT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/00-lib.sh"
require_root
load_config
require_supported_os

[[ "${CONFIRM_ROOT_KEY_LOGIN:-}" == "yes" ]] || die "拒绝执行最终 SSH 加固：请先确认 root key 登录正常，然后用 CONFIRM_ROOT_KEY_LOGIN=yes 重新执行。"

backup_path /etc/ssh/sshd_config
[[ -d /etc/ssh/sshd_config.d ]] && backup_path /etc/ssh/sshd_config.d
ensure_sshd_dropin_include

root_home="$(user_home root)"
[[ -s "$root_home/.ssh/authorized_keys" ]] || die "root 未安装 authorized_keys，不能禁用密码登录。"

write_hardening_file() {
  local kbd_directive="$1"
  write_root_file /etc/ssh/sshd_config.d/00-reality-landing-bootstrap-hardening.conf 0644 <<EOF
# Managed by reality-landing-bootstrap final hardening.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
${kbd_directive}
AuthenticationMethods publickey
PermitEmptyPasswords no
AllowUsers root
MaxAuthTries 3
MaxSessions 2
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}

write_hardening_file "KbdInteractiveAuthentication no"

if ! is_dry_run; then
  sshd="$(sshd_bin)"
  if ! "$sshd" -t >/tmp/reality-landing-bootstrap-sshd-test.err 2>&1; then
    if grep -qi 'KbdInteractiveAuthentication' /tmp/reality-landing-bootstrap-sshd-test.err; then
      warn "当前 OpenSSH 不支持 KbdInteractiveAuthentication，自动改用 ChallengeResponseAuthentication。"
      write_hardening_file "ChallengeResponseAuthentication no"
    else
      cat /tmp/reality-landing-bootstrap-sshd-test.err >&2
      die "sshd -t 未通过，已停止 reload。"
    fi
  fi
fi
rm -f /tmp/reality-landing-bootstrap-sshd-test.err

test_sshd_config

if ! is_dry_run; then
  effective="$("$(sshd_bin)" -T -C "user=root,host=localhost,addr=127.0.0.1")"
  grep -Eqi '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective" || die "PermitRootLogin prohibit-password 未生效。"
  grep -qi '^pubkeyauthentication yes$' <<<"$effective" || die "PubkeyAuthentication yes 未生效。"
  grep -qi '^passwordauthentication no$' <<<"$effective" || die "PasswordAuthentication no 未生效。"
  allowusers_line="$(grep -i '^allowusers ' <<<"$effective" || true)"
  [[ " $allowusers_line " =~ [[:space:]]root[[:space:]] ]] || die "AllowUsers 未包含 root。"
fi

reload_ssh

cat <<EOF

SSH 最终加固已应用。请不要关闭当前窗口，立刻另开终端测试：
$(for host in $(server_hosts); do
  printf '  ssh -p %s -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@%s\n' "$SSH_PORT" "$host"
  printf '  ssh -p %s -o PubkeyAuthentication=no -o PreferredAuthentications=password root@%s\n' "$SSH_PORT" "$host"
done)

预期：
  1. root key 登录成功。
  2. root 密码登录失败。
EOF
