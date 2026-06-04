# 安装流程

## 1. 准备配置

```bash
cp config.example.env config.env
nano config.env
cp landing-clients.example.csv landing-clients.csv
nano landing-clients.csv
```

`landing-clients.csv` 每行一个中转鸡入口。第一条空端口默认 `443`，后续空端口从 `EXTRA_PORT_START` 起分配。

## 2. SSH 初始化与加固

```bash
sudo bash bootstrap.sh --phase preflight
sudo bash bootstrap.sh --phase ssh-phase1
```

保留当前 SSH 窗口，另开窗口测试：

```powershell
ssh -p 22 -o PreferredAuthentications=publickey -o PasswordAuthentication=no root@服务器IP
```

确认 `whoami` 为 `root` 后：

```bash
sudo CONFIRM_ROOT_KEY_LOGIN=yes bash bootstrap.sh --phase ssh-final
```

## 3. fail2ban

```bash
sudo bash bootstrap.sh --phase fail2ban
```

## 4. Xray VLESS + Reality

```bash
sudo bash bootstrap.sh --phase xray
```

此阶段会安装 Xray、生成 Reality keypair/short-id、生成 `/etc/xray/config.json` 并重启服务。

## 5. 防火墙

```bash
sudo bash bootstrap.sh --phase firewall
```

UFW 会先放行 SSH，再按 `landing-clients.csv` 的 `allowed_sources` 精确放行到对应 `listen_port`。

## 6. 验证和输出链接

```bash
sudo bash bootstrap.sh --phase validate
sudo bash bootstrap.sh --phase output-links
```

链接输出：

```bash
sudo cat /root/reality-landing-bootstrap-links.txt
```
