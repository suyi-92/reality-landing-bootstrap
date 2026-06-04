# reality-landing-bootstrap 使用手册

`reality-landing-bootstrap` 是落地鸡配置器：它在落地 VPS 上安装 Xray，生成 VLESS + Reality 多入口配置，并为每个中转鸡输出一条专属 `vless://` 链接。

## 阶段

```text
preflight      -> 检查系统、配置、SSH、CSV
ssh-phase1     -> 准备 root 公钥登录
ssh-final      -> root 仅允许公钥登录，禁密码
fail2ban       -> 配置 SSH 防护
xray           -> 安装 Xray，生成 Reality 多入口配置
firewall       -> 按 allowed_sources 精确放行来源 IP 到端口
validate       -> 验证 Xray 配置、服务和监听端口
output-links   -> 生成每个中转鸡专属 vless:// 链接
rollback       -> 移除本项目 SSH hardening、UFW 规则并停止 Xray
```

## 最小配置

```bash
SERVER_ALIAS="landing-vps"
SERVER_DOMAIN="landing.example.com"
SERVER_IP_IPV4="1.2.3.4"
SSH_PORT="22"
ADMIN_PUBKEY="ssh-ed25519 AAAA..."
REALITY_SERVER_NAME="www.microsoft.com"
CLIENT_PORT_START="443"
EXTRA_PORT_START="51043"
```

## 客户端 CSV

```csv
tag,listen_port,allowed_sources,uuid,server_name,flow
relay-sj,,8.8.8.8,,www.microsoft.com,xtls-rprx-vision
relay-jp,51043,9.9.9.9;2001:db8::10/128,,www.microsoft.com,xtls-rprx-vision
```

`allowed_sources` 必须填写中转鸡公网 IP 或 CIDR。这样落地鸡的每个端口只接受指定中转鸡访问。

## 标准执行

全新服务器推荐直接远程一键执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/suyi-92/reality-landing-bootstrap/main/install.sh)
```

脚本会把项目安装/更新到 `/opt/reality-landing-bootstrap`。如果已经 clone 到本地，也可以在项目目录执行：

```bash
sudo bash install.sh
```

分阶段执行流程如下：

```bash
sudo bash bootstrap.sh --phase preflight
sudo bash bootstrap.sh --phase ssh-phase1
sudo CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
sudo bash bootstrap.sh --phase fail2ban
sudo bash bootstrap.sh --phase xray
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-links
```

## 中转鸡接入

在落地鸡上取出对应链接：

```bash
sudo cat /etc/reality-landing-bootstrap/links/relay-sj.txt
```

把该链接放到中转鸡项目的 `upstream-nodes.txt`：

```csv
tag,node_url,listen_port
landing-sj,vless://UUID@landing.example.com:443?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.microsoft.com&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F#landing-vps-relay-sj,
```
