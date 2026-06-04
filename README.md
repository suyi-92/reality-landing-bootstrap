# Reality Landing Bootstrap

这是一个无面板、配置驱动的落地鸡配置项目，用来把一台 Debian/Ubuntu VPS 配成 **Xray VLESS + Reality 落地服务器**。

支持系统：Debian GNU/Linux 11/12/13、Ubuntu 22.04/24.04。

它和 `reality-relay-bootstrap` 的关系：

- `reality-relay-bootstrap`：配置中转鸡，多入口转发到不同出口。
- `reality-landing-bootstrap`：配置落地鸡，给中转鸡提供专属上游 `vless://` 链接。

第一版不安装 3x-ui，不提供远程 HTTP 订阅服务，只在服务器本地生成每个中转鸡专属的完整 `vless://` 链接文件。

## 核心能力

- Xray VLESS + Reality 多入口。
- 每个中转鸡一个独立端口、独立 UUID、独立链接。
- UFW 按 `allowed_sources -> listen_port` 精确放行。
- Reality keypair、short-id、客户端 UUID 持久化；重复部署默认不轮换。
- root-only SSH 初始化与最终加固。
- fail2ban、UFW、Xray 配置验证和回滚。

## 快速使用

```bash
cp config.example.env config.env
nano config.env

cp landing-clients.example.csv landing-clients.csv
nano landing-clients.csv

sudo bash bootstrap.sh --phase preflight
sudo bash bootstrap.sh --phase ssh-phase1

# 另开窗口确认 root key 登录成功后：
sudo CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final

sudo bash bootstrap.sh --phase fail2ban
sudo bash bootstrap.sh --phase xray
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-links
```

全新服务器可以直接使用远程一键脚本。它会把项目安装/更新到 `/opt/reality-landing-bootstrap`，然后进入交互配置：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/suyi-92/reality-landing-bootstrap/main/install.sh)
```

如果已经下载了本仓库，也可以使用本地交互式一键脚本：

```bash
sudo bash install.sh
```

## landing-clients.csv

推荐字段：

```csv
tag,listen_port,allowed_sources,uuid,server_name,flow
```

- `tag`：中转鸡名称。
- `listen_port`：落地鸡对该中转鸡开放的入口端口，可留空。
- `allowed_sources`：允许访问该端口的中转鸡公网 IP/CIDR，多个用分号分隔。
- `uuid`：可留空，脚本自动生成并持久化。
- `server_name`：Reality 伪装域名，空则使用 `REALITY_SERVER_NAME`。
- `flow`：默认 `xtls-rprx-vision`。

端口分配规则：第一条空 `listen_port` 默认使用 `443`，后续空端口从 `EXTRA_PORT_START=51043` 起自动分配。

## 输出链接

部署完成后查看：

```bash
sudo cat /root/reality-landing-bootstrap-links.txt
sudo ls -l /etc/reality-landing-bootstrap/links/
```

每条链接都是标准格式：

```text
vless://UUID@你的服务器域名或IP:端口?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=伪装域名&pbk=REALITY_PUBLIC_KEY&sid=SHORT_ID&spx=%2F#节点名称
```

把对应链接放进中转鸡项目的 `upstream-nodes.txt`，即可让中转鸡某个入口端口转发到这台落地鸡。

## 后续新增中转鸡

已经部署好的落地鸡不需要重装。新增一台中转鸡时，只需要在落地鸡上追加一行客户端配置，然后重生成 Xray、UFW 和链接：

```bash
cd /opt/reality-landing-bootstrap
nano landing-clients.csv
```

追加一行，`allowed_sources` 填新中转鸡的公网 IP/CIDR；`listen_port` 和 `uuid` 可以留空：

```csv
relay-new,,中转鸡公网IP,,www.microsoft.com,xtls-rprx-vision
```

如果同一台中转鸡有 IPv4 和 IPv6，使用分号分隔：

```csv
relay-new,,1.2.3.4;2001:db8::10/128,,www.microsoft.com,xtls-rprx-vision
```

保存后执行：

```bash
sudo bash bootstrap.sh --phase xray
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-links
```

取出这台中转鸡专属链接：

```bash
sudo cat /etc/reality-landing-bootstrap/links/relay-new.txt
```

然后到对应中转鸡项目，把这条 `vless://...` 链接加入 `upstream-nodes.txt`：

```bash
cd /opt/reality-relay-bootstrap
nano upstream-nodes.txt
```

中转鸡侧追加示例：

```csv
landing-new,vless://UUID@landing.example.com:443?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.microsoft.com&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F#landing-vps-relay-new,
```

保存后在中转鸡执行：

```bash
sudo bash bootstrap.sh --phase singbox
sudo bash bootstrap.sh --phase firewall
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-nodes
```

## 安全边界

本项目通过“独立端口 + UFW 来源白名单 + 独立 UUID”隔离中转鸡。UFW 负责限制来源 IP，Xray 负责认证 UUID。不要把 `landing-clients.csv`、Reality 私钥或输出链接提交到公开仓库。
